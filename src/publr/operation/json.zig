//! `publr.operation.Json`: a value whose shape comes with the data, as an operation's
//! `In` or `Out` holds it (a record's document, a query's result). Publr itself keeps it as
//! the JSON text it stores; an installed plugin's module holds it in bytes read where they
//! lie (`publr.Value`), so it never writes or parses text to talk to Publr. A plugin
//! works with one the same way wherever it runs:
//!
//! ```zig
//! const facts = try record.document.as(Facts, ctx.arena());
//! const title = (try record.document.read(ctx.arena())).get("title");
//! const document = try Json.of(ctx.arena(), facts);
//! ```
const std = @import("std");
const builtin = @import("builtin");
const free_value = @import("../../sdk/free_value.zig");
const free_json = @import("../../sdk/free_json.zig");
const free_typed = @import("../../sdk/free_typed.zig");

pub const Error = error{ Invalid, OutOfMemory };

/// Whether this build is an installed plugin's module.
pub const sandboxed = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;

pub const Json = if (sandboxed) Laid else Text;

const label = "JSON (any value: `{ \"title\": \"Tea\" }`)";

/// As Publr keeps it: JSON text, written through untouched.
pub const Text = struct {
    text: []const u8,

    pub const publr_form = .json;
    pub const json_object = true;
    pub const json_label = label;
    /// An object of no keys: `{}`.
    pub const object: Text = .{
        .text = "{}",
    };

    /// What it is kept as, for telling two values apart: the same for the same value.
    pub fn written(json: Text) []const u8 {
        return json.text;
    }

    /// Each text as a value: documents read as text, answered as values.
    pub fn list(arena: std.mem.Allocator, texts: []const []const u8) error{OutOfMemory}![]Text {
        const made = try arena.alloc(Text, texts.len);

        for (texts, made) |text, *one| {
            std.debug.assert(text.len > 0);

            one.* = .{
                .text = text,
            };
        }

        std.debug.assert(made.len == texts.len);

        return made;
    }

    /// `value`, any struct, as one.
    pub fn of(arena: std.mem.Allocator, value: anytype) Error!Text {
        const text = std.json.Stringify.valueAlloc(arena, value, .{}) catch {
            return error.OutOfMemory;
        };

        std.debug.assert(text.len > 0);

        return .{
            .text = text,
        };
    }

    /// `value` as a record's document: a field holding nothing is left out.
    pub fn document(arena: std.mem.Allocator, value: anytype) Error!Text {
        const text = std.json.Stringify.valueAlloc(arena, value, .{
            .emit_null_optional_fields = false,
        }) catch return error.OutOfMemory;

        std.debug.assert(text.len > 0);

        return .{
            .text = text,
        };
    }

    /// It read as a `Shape`: fields by their names, one it has and the struct lacks left
    /// behind.
    pub fn as(json: Text, comptime Shape: type, arena: std.mem.Allocator) Error!Shape {
        std.debug.assert(json.text.len > 0);

        return std.json.parseFromSliceLeaky(Shape, arena, json.text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Invalid,
        };
    }

    /// It to read part by part: `read.get("title")`, `read.at(0)`.
    pub fn read(json: Text, arena: std.mem.Allocator) Error!free_value.Value {
        std.debug.assert(json.text.len > 0);

        return free_json.from_text(arena, json.text);
    }

    pub fn from(arena: std.mem.Allocator, made: free_value.Value) Error!Text {
        return .{
            .text = try free_json.text_of(arena, made),
        };
    }

    pub fn jsonStringify(json: Text, writer: anytype) !void {
        std.debug.assert(json.text.len > 0);

        try writer.beginWriteRaw();
        try writer.writer.writeAll(json.text);
        writer.endWriteRaw();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Text {
        const parsed = try std.json.Value.jsonParse(allocator, source, options);

        return jsonParseFromValue(allocator, parsed, options);
    }

    /// From a value already parsed, as a modifier reads what it changes.
    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Text {
        std.debug.assert(options.max_value_len == null or options.max_value_len.? > 0);

        const text = std.json.Stringify.valueAlloc(allocator, source, .{}) catch {
            return error.OutOfMemory;
        };

        std.debug.assert(text.len > 0);

        return .{
            .text = text,
        };
    }
};

/// As an installed plugin's module holds it: the value's own bytes, handed over as they
/// lie.
pub const Laid = struct {
    bytes: []const u8 = &.{@backingInt(free_value.Kind.null)},

    pub const publr_form = .free;
    pub const json_object = true;
    pub const json_label = label;
    pub const object: Laid = .{
        .bytes = &.{ @backingInt(free_value.Kind.map), 0, 0, 0, 0, 0, 0, 0, 0 },
    };

    pub fn written(json: Laid) []const u8 {
        return json.bytes;
    }

    /// An example written as JSON, read when the plugin is built.
    pub fn example_of(comptime text: []const u8) Laid {
        return .{
            .bytes = comptime @import("../../sdk/free_comptime.zig").of(text),
        };
    }

    pub fn of(arena: std.mem.Allocator, value: anytype) Error!Laid {
        const made = try free_typed.of(arena, value);

        std.debug.assert(made.bytes.len > 0);

        return .{
            .bytes = made.bytes,
        };
    }

    /// `value` as a record's document: a field holding nothing is left out.
    pub fn document(arena: std.mem.Allocator, value: anytype) Error!Laid {
        const made = try free_typed.document_of(arena, value);

        std.debug.assert(made.bytes.len > 0);

        return .{
            .bytes = made.bytes,
        };
    }

    pub fn as(json: Laid, comptime Shape: type, arena: std.mem.Allocator) Error!Shape {
        std.debug.assert(json.bytes.len > 0);

        return free_typed.as(Shape, arena, .{
            .bytes = json.bytes,
        });
    }

    pub fn read(json: Laid, arena: std.mem.Allocator) Error!free_value.Value {
        _ = arena;

        std.debug.assert(json.bytes.len > 0);

        return .{
            .bytes = json.bytes,
        };
    }

    pub fn from(arena: std.mem.Allocator, made: free_value.Value) Error!Laid {
        _ = arena;

        std.debug.assert(made.bytes.len > 0);

        return .{
            .bytes = made.bytes,
        };
    }

    /// For a plugin that keeps JSON of its own: written as the JSON it stands for.
    pub fn jsonStringify(json: Laid, writer: anytype) !void {
        std.debug.assert(json.bytes.len > 0);

        try writer.beginWriteRaw();
        free_json.write(writer.writer, .{
            .bytes = json.bytes,
        }) catch return error.WriteFailed;
        writer.endWriteRaw();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Laid {
        const parsed = try std.json.Value.jsonParse(allocator, source, options);

        return jsonParseFromValue(allocator, parsed, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Laid {
        std.debug.assert(options.max_value_len == null or options.max_value_len.? > 0);

        const made = free_json.from_tree(allocator, source) catch return error.OutOfMemory;

        return .{
            .bytes = made.bytes,
        };
    }
};

test "Json reads from text and from a value already parsed alike" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const memory = arena_state.allocator();
    const Line = struct {
        total: Text,
    };
    const text = "{\"total\":{\"GBP\":1800}}";
    const from_text = try std.json.parseFromSliceLeaky(Line, memory, text, .{});
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, memory, text, .{});
    const from_value = try std.json.parseFromValueLeaky(Line, memory, parsed, .{});

    try std.testing.expectEqualStrings("{\"GBP\":1800}", from_text.total.text);
    try std.testing.expectEqualStrings(from_text.total.text, from_value.total.text);
}

test "a plugin works with one the same way in either form" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Facts = struct {
        title: []const u8,
        count: u32 = 1,
    };
    const facts: Facts = .{
        .title = "Tea",
        .count = 3,
    };

    inline for (.{ Text, Laid }) |Form| {
        const json = try Form.of(arena, facts);
        const back = try json.as(Facts, arena);
        const held = try json.read(arena);

        try std.testing.expectEqualStrings("Tea", back.title);
        try std.testing.expectEqual(@as(u32, 3), back.count);
        try std.testing.expectEqual(@as(?i64, 3), held.get("count").?.int());
        try std.testing.expectEqualStrings("Tea", (try (try Form.from(arena, held)).as(
            Facts,
            arena,
        )).title);
    }
}
