//! `publr.field.kind(Value, .{ .name, .validate, .text, .editor, .icon })`: a field kind a plugin
//! brings. Its storage follows `Value` (text, a whole number, a number, yes or no, or a struct
//! kept as JSON), its words are the `///` on `Value`, `.validate` runs on every write with
//! the same `problems` as an operation's, and `.text` (`fn (ctx, value) Error![]const u8`)
//! is how a value reads in list cells, search and on the site. `.editor` is a view
//! (`publr.views.all.PlaceEditor`) the edit form draws in the plugin frame; its `ctx` carries
//! the value, its problems, the field's options and `change(value)`, which hands it to the form.
const std = @import("std");
const kinds = @import("../../model/kinds.zig");
const field_model = @import("../../model/field.zig");
const plugin_define = @import("define.zig");
const operation_define = @import("operation_define.zig");
const sdk = @import("../../sdk.zig");
const plugin_context = @import("context.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");

const option_names = [_][]const u8{ "name", "validate", "text", "editor", "icon" };

pub fn kind(comptime Value: type, comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!listed(given)) {
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

/// The kind as the core keeps it, named under the plugin (`places.location`).
pub fn described(
    comptime Definition: type,
    comptime plugin: []const u8,
    comptime Docs: type,
) kinds.Kind {
    comptime {
        const Value = Definition.Shape;
        const id = plugin ++ "." ++ Definition.verb;
        _ = plugin_define.words(Docs, @typeName(Value)) orelse @compileError("field " ++
            "kind " ++ id ++ ": " ++ @typeName(Value) ++ " needs a `///` comment: its name, " ++
            "then what it holds");
        const options = Definition.given;
        const native = plugin_context.Mode.native == @import("guest.zig").mode;
        const texted = @hasField(@TypeOf(options), "text") and native;
        const edited = @hasField(@TypeOf(options), "editor") and native;

        return .{
            .id = id,
            .label = std.mem.trimEnd(u8, plugin_define.first(Docs, @typeName(Value)).?, "."),
            .description = plugin_define.rest(Docs, @typeName(Value)).?,
            .icon = if (@hasField(@TypeOf(options), "icon")) options.icon else "box",
            .storage = storage_of(id, Value),
            .control = control_of(Value),
            .check = if (@hasField(@TypeOf(options), "validate"))
                &Checked(Definition).check
            else
                null,
            .text = if (texted) &Texted(Definition).text else null,
            .editor = if (edited) &Edited(Definition).draw else null,
            .searchable_allowed = texted,
        };
    }
}

fn storage_of(comptime id: []const u8, comptime Value: type) kinds.Storage {
    comptime {
        std.debug.assert(id.len > 0);

        if (Value == []const u8) {
            return .text;
        }

        return switch (@typeInfo(Value)) {
            .int => .int,
            .float => .real,
            .bool => .bool,
            .@"struct" => .long,
            else => @compileError("field kind " ++ id ++ ": " ++ @typeName(Value) ++
                " is not plain data"),
        };
    }
}

fn control_of(comptime Value: type) kinds.Control {
    comptime {
        std.debug.assert(@sizeOf(Value) <= 1 << 16);

        if (Value == []const u8) {
            return .input;
        }

        return switch (@typeInfo(Value)) {
            .int, .float => .number,
            .bool => .checkbox,
            else => .json,
        };
    }
}

/// The core's check for the kind: the stored value read back into `Value`, then the plugin's
/// `.validate`, each problem under the field's path.
fn Checked(comptime Definition: type) type {
    return struct {
        fn check(
            def: field_model.Def,
            value: std.json.Value,
            path: []const u8,
            problems: *field_model.Problems,
        ) void {
            std.debug.assert(def.name.len > 0);
            std.debug.assert(path.len > 0);

            var buffer: [16 << 10]u8 = undefined;
            var memory: std.heap.FixedBufferAllocator = .init(&buffer);
            const arena = memory.allocator();
            const parsed = decoded(Definition.Shape, arena, value) catch {
                problems.add(path, "not a value of this kind");
                return;
            };
            var found: operation_define.Problems(Wrapped(Definition.Shape)) = .{};

            Definition.given.validate(parsed, &found);

            for (found.slice()) |problem| {
                problems.add(path, problem.message);
            }
        }
    };
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

/// The plugin's `.text` over a stored value read back into `Value`.
fn Texted(comptime Definition: type) type {
    return struct {
        fn text(ctx: *anyopaque, id: []const u8, value: std.json.Value) ?[]const u8 {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));

            std.debug.assert(id.len > 0);

            const parsed = decoded(Definition.Shape, inner.arena, value);
            var wrapped: plugin_context.PluginCtx = .{
                .inner = inner,
            };

            std.debug.assert(inner.now_ms >= 0);

            return Definition.given.text(&wrapped, parsed catch return null) catch null;
        }
    };
}

/// The plugin's `.editor` view drawn whole, for the plugin frame, with what the caller's
/// `view.editor` says: the value, its problems and the field's options in its `ctx`.
fn Edited(comptime Definition: type) type {
    return struct {
        fn draw(ctx: *anyopaque, base: []const u8) ?[]const u8 {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
            var wrapped: plugin_context.PluginCtx = .{
                .inner = inner,
            };

            std.debug.assert(inner.view.editor != null);

            return @import("views.zig").render(&wrapped, base, Definition.given.editor, .{}) catch
                null;
        }
    };
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

/// The kind as an installed plugin's manifest carries it.
pub fn manifested(comptime Definition: type, comptime Docs: type) sandboxed_plugin.FieldKind {
    comptime {
        const Value = Definition.Shape;
        const options = Definition.given;

        _ = plugin_define.words(Docs, @typeName(Value)) orelse @compileError("field kind " ++
            Definition.verb ++ ": " ++ @typeName(Value) ++ " needs a `///` comment: its " ++
            "name, then what it holds");

        return .{
            .name = Definition.verb,
            .label = std.mem.trimEnd(u8, plugin_define.first(Docs, @typeName(Value)).?, "."),
            .description = plugin_define.rest(Docs, @typeName(Value)).?,
            .icon = if (@hasField(@TypeOf(options), "icon")) options.icon else "box",
            .storage = storage_of(Definition.verb, Value),
            .control = control_of(Value),
            .validates = @hasField(@TypeOf(options), "validate"),
            .texts = @hasField(@TypeOf(options), "text"),
        };
    }
}

/// What an installed kind's `validate` and `text` are handed: the stored value.
pub const Stored = struct {
    value: std.json.Value,
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

/// An installed plugin's kind as core keeps it, named under the plugin: its `.validate` and
/// `.text` run in the sandbox by its id, with the context of the write or read.
pub fn installed(id: []const u8, declared: sandboxed_plugin.FieldKind) kinds.Kind {
    std.debug.assert(std.mem.indexOfScalar(u8, id, '.') != null);

    return .{
        .id = id,
        .label = declared.label,
        .description = declared.description,
        .icon = declared.icon,
        .storage = declared.storage,
        .control = declared.control,
        .check = if (declared.validates) &installed_check else null,
        .text = if (declared.texts) &installed_text else null,
        .searchable_allowed = declared.texts,
    };
}

fn installed_check(
    def: field_model.Def,
    value: std.json.Value,
    path: []const u8,
    problems: *field_model.Problems,
) void {
    std.debug.assert(path.len > 0);

    const reader = problems.reader orelse return problems.add(path, "can't be checked here");
    const ctx: *sdk.Ctx = @ptrCast(@alignCast(reader));
    const sandboxed = ctx.sandboxed_plugins orelse return problems.add(path, "can't be checked");
    const input = sdk.stringify(ctx.arena, Stored{
        .value = value,
    }) catch return problems.add(path, "can't be checked");
    const answered = sandboxed.extra(ctx, .kind_validate, def.kind, input) catch {
        return problems.add(path, "can't be checked: its plugin did not answer");
    };
    const messages = std.json.parseFromSliceLeaky([]const []const u8, ctx.arena, answered, .{
        .allocate = .alloc_always,
    }) catch return problems.add(path, "can't be checked: its plugin did not answer");

    for (messages) |message| {
        if (message.len > 0) {
            problems.add(path, message);
        }
    }
}

fn installed_text(ctx: *anyopaque, id: []const u8, value: std.json.Value) ?[]const u8 {
    const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
    const sandboxed = inner.sandboxed_plugins orelse return null;
    const input = sdk.stringify(inner.arena, Stored{
        .value = value,
    }) catch return null;
    const answered = sandboxed.extra(inner, .kind_text, id, input) catch return null;

    std.debug.assert(id.len > 0);

    return std.json.parseFromSliceLeaky([]const u8, inner.arena, answered, .{
        .allocate = .alloc_always,
    }) catch null;
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

fn listed(comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (option_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}

test "a field kind from its value's struct and words" {
    const Location = struct {
        lat: f64,
        lng: f64,
    };
    const Docs = @import("define.zig").Words(.{
        .{ @typeName(Location), "Location\nA point on a map." },
    });
    const Kind = kind(Location, .{
        .name = "location",
        .validate = struct {
            fn validate(value: Location, problems: *operation_define.Problems(Location)) void {
                if (value.lat < -90 or value.lat > 90) {
                    problems.add(.lat, "Must be between -90 and 90");
                }
            }
        }.validate,
        .text = struct {
            fn text(ctx: *plugin_context.PluginCtx, value: Location) sdk.Error![]const u8 {
                return ctx.print("{d}, {d}", .{ value.lat, value.lng });
            }
        }.text,
    });
    const declared = comptime described(Kind, "places", Docs);

    try std.testing.expectEqualStrings("places.location", declared.id);
    try std.testing.expectEqualStrings("Location", declared.label);
    try std.testing.expectEqual(kinds.Storage.long, declared.storage);
    try std.testing.expect(declared.check != null);
    try std.testing.expect(declared.searchable_allowed);

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var ctx = harness.ctx(.system);
    const stored: std.json.Value = .{
        .string = "{\"lat\":52.5,\"lng\":21}",
    };

    try std.testing.expectEqualStrings("52.5, 21", declared.text.?(&ctx, declared.id, stored).?);
    try std.testing.expect(declared.text.?(&ctx, declared.id, .{
        .string = "not a place",
    }) == null);
}
