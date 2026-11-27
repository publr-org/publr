//! `publr.field.kind(Value, .{ .name, .validate, .text, .editor, .icon })`: a field kind a plugin
//! brings. Its storage follows `Value` (text, a whole number, a number, yes or no, or a struct
//! kept as JSON), its words are the `///` on `Value`, `.validate` runs on every write with
//! the same `problems` as an operation's, and `.text` (`fn (ctx, value) Error![]const u8`)
//! is how a value reads in list cells, search and on the site. `.editor` is a view
//! (`publr.views.all.PlaceEditor`) the edit form draws in the plugin frame; its `ctx` carries
//! the value, its problems, the field's options and `change(value)`, which hands it to the form.
//! `.code_only = true` keeps it out of the type builder: only the plugin's code puts it on a
//! type, in a group it places on another plugin's records (a product's weight).
const std = @import("std");
const Json = @import("../operation.zig").Json;
const plugin_define = @import("define.zig");
const operation_define = @import("operation_define.zig");

const option_names = [_][]const u8{ "name", "validate", "text", "editor", "icon", "code_only" };

pub fn kind(comptime Value: type, comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!plugin_define.listed_in(&option_names, given)) {
                @compileError("field kind " ++ options.name ++ ": no option `" ++ given ++ "`");
            }
        }

        return struct {
            pub const publr_field_kind_definition = true;
            pub const Shape = Value;
            pub const verb = options.name;
            pub const given = options;
        };
    }
}

pub fn is_definition(comptime Type: type) bool {
    return @typeInfo(Type) == .@"struct" and @hasDecl(Type, "publr_field_kind_definition");
}

/// A stored value read back into `Value`: a struct is kept as its JSON text.
pub fn decoded(comptime Value: type, arena: std.mem.Allocator, value: std.json.Value) !Value {
    const options: std.json.ParseOptions = .{
        .ignore_unknown_fields = true,
    };

    std.debug.assert(@sizeOf(Value) <= 1 << 16);

    if (value == .string and Value != []const u8) {
        return std.json.parseFromSliceLeaky(Value, arena, value.string, options);
    }

    return std.json.parseFromValueLeaky(Value, arena, value, options);
}

/// The plugin's kinds made with `publr.field.kind`, as it lists them in `.field_kinds`.
pub fn definitions_of(comptime Plugin: type) []const type {
    comptime {
        var list: []const type = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        const declared = @hasDecl(Plugin, "options") and
            @hasField(@TypeOf(Plugin.options), "field_kinds");

        if (!declared) {
            return list;
        }

        for (Plugin.options.field_kinds) |Listed| {
            if (@TypeOf(Listed) == type and is_definition(Listed)) {
                list = list ++ &[_]type{Listed};
            }
        }

        const done = list;

        return done;
    }
}

/// What an installed kind's `validate` and `text` are handed: the stored value, and, when
/// it is kept as text holding JSON, what that text reads as.
pub const Stored = struct {
    value: Json,
    parsed: ?Json = null,
};

/// A stored value read as the kind's own type, in an installed plugin's module: text
/// holding JSON is read as what it holds, unless the kind's value is a text itself.
pub fn stored_as(comptime Value: type, arena: std.mem.Allocator, stored: Stored) !Value {
    const held = try stored.value.read(arena);

    std.debug.assert(@sizeOf(Value) <= 1 << 16);

    if (held.kind() == .text and Value != []const u8) {
        const parsed = stored.parsed orelse return error.Invalid;

        return parsed.as(Value, arena);
    }

    return stored.value.as(Value, arena);
}

/// `problems_of` over a value handed to an installed plugin's module.
pub fn problems_stored(
    comptime Definition: type,
    arena: std.mem.Allocator,
    stored: Stored,
) []const []const u8 {
    const parsed = stored_as(Definition.Shape, arena, stored) catch {
        return &.{"not a value of this kind"};
    };

    std.debug.assert(@sizeOf(Definition.Shape) <= 1 << 16);

    return problems_found(Definition, arena, parsed);
}

/// What an installed kind's `editor` is handed: the path its frame is served under.
pub const Drawn = struct {
    base: []const u8,
};

/// The plugin's `.validate` over a stored value read back into `Value`: each problem's
/// message, or one when it is no value of the kind.
pub fn problems_of(
    comptime Definition: type,
    arena: std.mem.Allocator,
    value: std.json.Value,
) []const []const u8 {
    const parsed = decoded(Definition.Shape, arena, value) catch {
        return &.{"not a value of this kind"};
    };

    std.debug.assert(@sizeOf(Definition.Shape) <= 1 << 16);

    return problems_found(Definition, arena, parsed);
}

fn problems_found(
    comptime Definition: type,
    arena: std.mem.Allocator,
    parsed: Definition.Shape,
) []const []const u8 {
    var found: operation_define.Problems(Wrapped(Definition.Shape)) = .{};

    if (comptime @hasField(@TypeOf(Definition.given), "validate")) {
        Definition.given.validate(parsed, &found);
    }

    const messages = arena.alloc([]const u8, found.slice().len) catch {
        return &.{"not checked: out of memory"};
    };

    for (found.slice(), messages) |problem, *message| {
        message.* = problem.message;
    }

    return messages;
}

/// A struct value's own fields name its problems; any other value is one problem, `value`.
fn Wrapped(comptime Value: type) type {
    if (@typeInfo(Value) == .@"struct") {
        return Value;
    }

    return struct {
        value: Value,
    };
}
