//! How a type's records are edited: `form` (a control per field) or `visual` (the block
//! editor over one rich text field, named by `editor_config` `{"field": …}` or else the
//! type's first rich text field).
const std = @import("std");
const field = @import("field.zig");

pub const form = "form";
pub const visual = "visual";
pub const config_bytes_max: u32 = 256;

const Config = struct {
    field: []const u8 = "",
};

pub fn is_visual(editor: []const u8) bool {
    return std.mem.eql(u8, editor, visual);
}

/// The rich text field a visual type writes; null for a form type, or a visual one whose
/// config names nothing usable.
pub fn field_of(
    editor: []const u8,
    config: []const u8,
    fields: []const field.Def,
) ?*const field.Def {
    std.debug.assert(fields.len <= field.fields_max);

    if (!is_visual(editor)) {
        return null;
    }

    const named = configured_field(config) orelse return null;

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

/// The field name the config asks for: empty when it names none, null when the config is
/// not an object of that shape.
fn configured_field(config: []const u8) ?[]const u8 {
    std.debug.assert(config_bytes_max >= 64);

    if (config.len == 0 or config.len > config_bytes_max) {
        return null;
    }

    var buffer: [config_bytes_max * 4]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const parsed = std.json.parseFromSliceLeaky(Config, fixed.allocator(), config, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return null;

    std.debug.assert(parsed.field.len <= config.len);

    return parsed.field;
}

pub fn validate(
    editor: []const u8,
    config: []const u8,
    fields: []const field.Def,
    problems: *field.Problems,
) void {
    std.debug.assert(problems.len <= field.problems_max);

    if (!std.mem.eql(u8, editor, form) and !is_visual(editor)) {
        problems.add("editor", "editor must be form or visual");
        return;
    }

    if (configured_field(config) == null) {
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

    try std.testing.expectEqualStrings("intro", field_of(visual, "{}", &fields).?.name);
    try std.testing.expectEqualStrings(
        "body",
        field_of(visual, "{\"field\":\"body\"}", &fields).?.name,
    );
    try std.testing.expect(field_of(visual, "{\"field\":\"title\"}", &fields) == null);
    try std.testing.expect(field_of(visual, "{\"field\":\"notes\"}", &fields) == null);
    try std.testing.expect(field_of(visual, "[1]", &fields) == null);
    try std.testing.expect(field_of(form, "{}", &fields) == null);
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
        config: []const u8,
        fields: []const field.Def,
        ok: bool,
    };
    const cases = [_]Case{
        .{
            .editor = form,
            .config = "{}",
            .fields = &plain,
            .ok = true,
        },
        .{
            .editor = visual,
            .config = "{}",
            .fields = &rich,
            .ok = true,
        },
        .{
            .editor = visual,
            .config = "{}",
            .fields = &plain,
            .ok = false,
        },
        .{
            .editor = visual,
            .config = "{\"field\":\"x\"}",
            .fields = &rich,
            .ok = false,
        },
        .{
            .editor = "block",
            .config = "{}",
            .fields = &rich,
            .ok = false,
        },
        .{
            .editor = form,
            .config = "nope",
            .fields = &plain,
            .ok = false,
        },
        .{
            .editor = form,
            .config = "",
            .fields = &plain,
            .ok = false,
        },
    };

    for (cases) |case| {
        var problems: field.Problems = .{};
        validate(case.editor, case.config, case.fields, &problems);
        try std.testing.expectEqual(case.ok, problems.is_empty());
    }
}
