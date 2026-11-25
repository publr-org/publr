//! How a type's records are edited: `form` (a control per field) or `visual` (the block
//! editor over one rich text field, named by `editor_config` `{"field": …}` or else the
//! type's first rich text field).
const std = @import("std");
const field = @import("field.zig");

pub const form = "form";
pub const visual = "visual";
pub const config_bytes_max: u32 = 256;

/// A type's `editor_config`: `{"field": name}`, the rich text field a visual type writes;
/// `{}` for its first one.
pub const Config = struct {
    field: []const u8 = "",

    pub const publr_form = .fields;

    /// Written as text holding the object, as releases before 0.8 wrote and still read it.
    pub fn jsonStringify(config: Config, writer: anytype) !void {
        std.debug.assert(config.field.len <= config_bytes_max);

        var buffer: [config_bytes_max * 2]u8 = undefined;

        try writer.write(config.text(&buffer));
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Config {
        const value = try std.json.Value.jsonParse(allocator, source, options);

        return jsonParseFromValue(allocator, value, options);
    }

    /// A definition stored before the config was a value keeps it as text holding the
    /// object: read as the object it holds.
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Config {
        const given = if (source == .string)
            std.json.parseFromSliceLeaky(std.json.Value, allocator, source.string, options) catch {
                return error.UnexpectedToken;
            }
        else
            source;

        if (given != .object) {
            return error.UnexpectedToken;
        }

        const named = given.object.get("field") orelse return .{};

        if (named != .string or named.string.len > config_bytes_max) {
            return error.UnexpectedToken;
        }

        return .{
            .field = named.string,
        };
    }

    /// The config as the JSON text a column keeps, written into `buffer`.
    pub fn text(config: Config, buffer: *[config_bytes_max * 2]u8) []const u8 {
        std.debug.assert(config.field.len <= config_bytes_max);

        if (config.field.len == 0) {
            return "{}";
        }

        var writer = std.Io.Writer.fixed(buffer);
        const object: struct {
            field: []const u8,
        } = .{
            .field = config.field,
        };

        std.json.Stringify.value(object, .{}, &writer) catch return "{}";

        std.debug.assert(writer.end >= 2);

        return writer.buffered();
    }
};

pub fn is_visual(editor: []const u8) bool {
    return std.mem.eql(u8, editor, visual);
}

/// The rich text field a visual type writes; null for a form type, or a visual one whose
/// config names nothing usable.
pub fn field_of(
    editor: []const u8,
    config: Config,
    fields: []const field.Def,
) ?*const field.Def {
    std.debug.assert(fields.len <= field.fields_max);

    if (!is_visual(editor) or config.field.len > config_bytes_max) {
        return null;
    }

    const named = config.field;

    for (fields) |*candidate| {
        const rich = std.mem.eql(u8, candidate.kind, "richtext") and !candidate.many;
        const wanted = named.len == 0 or std.mem.eql(u8, candidate.name, named);

        if (rich and wanted) {
            return candidate;
        }
    }

    std.debug.assert(fields.len <= field.fields_max);

    return null;
}

pub fn validate(
    editor: []const u8,
    config: Config,
    fields: []const field.Def,
    problems: *field.Problems,
) void {
    std.debug.assert(problems.len <= field.problems_max);

    if (!std.mem.eql(u8, editor, form) and !is_visual(editor)) {
        problems.add("editor", "editor must be form or visual");
        return;
    }

    if (config.field.len > field.name_len_max) {
        problems.add("editor_config", "editor_config must be an object, {\"field\": name}");
        return;
    }

    if (is_visual(editor) and field_of(editor, config, fields) == null) {
        problems.add("editor_config", "a visual type needs a single rich text field " ++
            "to write, named by editor_config's field or its first one");
    }
}

test "a visual type writes its named rich text field, or its first one" {
    const fields = [_]field.Def{
        .{
            .name = "title",
            .label = "Title",
            .kind = "string",
        },
        .{
            .name = "intro",
            .label = "Intro",
            .kind = "richtext",
        },
        .{
            .name = "body",
            .label = "Body",
            .kind = "richtext",
        },
        .{
            .name = "notes",
            .label = "Notes",
            .kind = "richtext",
            .many = true,
        },
    };

    try std.testing.expectEqualStrings("intro", field_of(visual, .{}, &fields).?.name);
    try std.testing.expectEqualStrings(
        "body",
        field_of(visual, .{
            .field = "body",
        }, &fields).?.name,
    );
    try std.testing.expect(field_of(visual, .{
        .field = "title",
    }, &fields) == null);
    try std.testing.expect(field_of(visual, .{
        .field = "notes",
    }, &fields) == null);
    try std.testing.expect(field_of(form, .{}, &fields) == null);
}

test "only form and visual pass, and a visual type needs its field" {
    const plain = [_]field.Def{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
    }};
    const rich = [_]field.Def{.{
        .name = "body",
        .label = "Body",
        .kind = "richtext",
    }};
    const Case = struct {
        editor: []const u8,
        config: Config,
        fields: []const field.Def,
        ok: bool,
    };
    const cases = [_]Case{
        .{
            .editor = form,
            .config = .{},
            .fields = &plain,
            .ok = true,
        },
        .{
            .editor = visual,
            .config = .{},
            .fields = &rich,
            .ok = true,
        },
        .{
            .editor = visual,
            .config = .{},
            .fields = &plain,
            .ok = false,
        },
        .{
            .editor = visual,
            .config = .{
                .field = "x",
            },
            .fields = &rich,
            .ok = false,
        },
        .{
            .editor = "block",
            .config = .{},
            .fields = &rich,
            .ok = false,
        },
    };

    for (cases) |case| {
        var problems: field.Problems = .{};
        validate(case.editor, case.config, case.fields, &problems);
        try std.testing.expectEqual(case.ok, problems.is_empty());
    }
}

test "a config reads as an object, and as the text a stored definition kept it in" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Held = struct {
        editor_config: Config = .{},
    };
    const cases = [_][]const u8{
        "{\"editor_config\":{\"field\":\"body\"}}",
        "{\"editor_config\":\"{\\\"field\\\":\\\"body\\\"}\"}",
    };

    for (cases) |case| {
        const held = try std.json.parseFromSliceLeaky(Held, arena, case, .{});

        try std.testing.expectEqualStrings("body", held.editor_config.field);
    }

    for ([_][]const u8{ "{\"editor_config\":[1]}", "{\"editor_config\":{\"field\":1}}" }) |bad| {
        try std.testing.expectError(
            error.UnexpectedToken,
            std.json.parseFromSliceLeaky(Held, arena, bad, .{}),
        );
    }

    var buffer: [config_bytes_max * 2]u8 = undefined;
    const named: Config = .{
        .field = "body",
    };

    try std.testing.expectEqualStrings("{}", (Config{}).text(&buffer));
    try std.testing.expectEqualStrings("{\"field\":\"body\"}", named.text(&buffer));
}

test "a config is written as the text holding it, which releases before 0.8 read" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Held = struct {
        editor_config: Config = .{},
    };
    const named: Held = .{
        .editor_config = .{
            .field = "body",
        },
    };
    const written = try std.json.Stringify.valueAlloc(arena, named, .{});

    try std.testing.expectEqualStrings(
        "{\"editor_config\":\"{\\\"field\\\":\\\"body\\\"}\"}",
        written,
    );

    const read = try std.json.parseFromSliceLeaky(Held, arena, written, .{});

    try std.testing.expectEqualStrings("body", read.editor_config.field);
}
