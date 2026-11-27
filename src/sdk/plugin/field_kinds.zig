//! A plugin's field kinds (`publr.field.kind`) as core keeps them: a descriptor naming the
//! kind under its plugin, with the plugin's `.validate`, `.text` and `.editor` behind it, run
//! in the process compiled in, in the sandbox installed.
const std = @import("std");
const definer = @import("../../publr/plugin/field_kind_define.zig");
const plugin_define = @import("../../publr/plugin/define.zig");
const kinds = @import("../../model/kinds.zig");
const field_model = @import("../../model/field.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const sdk = @import("../../sdk.zig");
const Error = @import("../../publr/operation.zig").Error;
const plugin_context = @import("context.zig");
const views = @import("../../publr/plugin/views.zig");
const operation_define = @import("../../publr/plugin/operation_define.zig");

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
            .icon = if (@hasField(@TypeOf(options), "icon")) options.icon else "package",
            .storage = storage_of(id, Value),
            .control = control_of(Value),
            .check = if (@hasField(@TypeOf(options), "validate"))
                &Checked(Definition).check
            else
                null,
            .text = if (texted) &Texted(Definition).text else null,
            .editor = if (edited) &Edited(Definition).draw else null,
            .searchable_allowed = texted,
            .code_only = code_only_of(options),
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

            for (definer.problems_of(Definition, arena, value)) |message| {
                problems.add(path, message);
            }
        }
    };
}

/// The plugin's `.text` over a stored value read back into `Value`.
fn Texted(comptime Definition: type) type {
    return struct {
        fn text(ctx: *anyopaque, id: []const u8, value: std.json.Value) ?[]const u8 {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));

            std.debug.assert(id.len > 0);

            const parsed = definer.decoded(Definition.Shape, inner.arena, value);
            var wrapped: plugin_context.HostApi = .{
                .inner = inner,
            };

            std.debug.assert(inner.now_ms >= 0);

            return Definition.given.text(wrapped.ctx(), parsed catch return null) catch null;
        }
    };
}

/// The plugin's `.editor` view drawn whole, for the plugin frame, with what the caller's
/// `view.editor` says: the value, its problems and the field's options in its `ctx`.
fn Edited(comptime Definition: type) type {
    return struct {
        fn draw(ctx: *anyopaque, id: []const u8, base: []const u8) ?[]const u8 {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));

            std.debug.assert(id.len > 0);
            var wrapped: plugin_context.HostApi = .{
                .inner = inner,
            };

            std.debug.assert(inner.view.editor != null);

            return views.render(wrapped.ctx(), base, Definition.given.editor, .{}) catch
                null;
        }
    };
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
            .icon = if (@hasField(@TypeOf(options), "icon")) options.icon else "package",
            .storage = storage_of(Definition.verb, Value),
            .control = control_of(Value),
            .validates = @hasField(@TypeOf(options), "validate"),
            .texts = @hasField(@TypeOf(options), "text"),
            .edits = @hasField(@TypeOf(options), "editor"),
            .code_only = code_only_of(options),
        };
    }
}

/// `Stored` as core hands it over.
const Handed = struct {
    value: std.json.Value,
    parsed: ?std.json.Value = null,

    fn of(arena: std.mem.Allocator, value: std.json.Value) Handed {
        std.debug.assert(value != .number_string);

        if (value != .string) {
            return .{
                .value = value,
            };
        }

        return .{
            .value = value,
            .parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, value.string, .{}) catch
                null,
        };
    }
};

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
        .editor = if (declared.edits) &installed_editor else null,
        .searchable_allowed = declared.texts,
        .code_only = declared.code_only,
    };
}

fn code_only_of(comptime options: anytype) bool {
    comptime {
        std.debug.assert(options.name.len > 0);

        return @hasField(@TypeOf(options), "code_only") and options.code_only;
    }
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
    const input = sdk.stringify(ctx.arena, Handed.of(ctx.arena, value)) catch {
        return problems.add(path, "can't be checked");
    };
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
    const input = sdk.stringify(inner.arena, Handed.of(inner.arena, value)) catch return null;
    const answered = sandboxed.extra(inner, .kind_text, id, input) catch return null;

    std.debug.assert(id.len > 0);

    return std.json.parseFromSliceLeaky([]const u8, inner.arena, answered, .{
        .allocate = .alloc_always,
    }) catch null;
}

/// An installed kind's `.editor` drawn in the sandbox with the caller's view: its document,
/// or null when it could not be drawn.
fn installed_editor(ctx: *anyopaque, id: []const u8, base: []const u8) ?[]const u8 {
    const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
    const sandboxed = inner.sandboxed_plugins orelse return null;
    const input = sdk.stringify(inner.arena, definer.Drawn{
        .base = base,
    }) catch return null;
    const answered = sandboxed.extra(inner, .kind_editor, id, input) catch return null;

    std.debug.assert(id.len > 0);
    std.debug.assert(inner.view.editor != null);

    return std.json.parseFromSliceLeaky([]const u8, inner.arena, answered, .{
        .allocate = .alloc_always,
    }) catch null;
}

test "a field kind from its value's struct and words" {
    const Location = struct {
        lat: f64,
        lng: f64,
    };
    const Docs = plugin_define.Words(.{
        .{ @typeName(Location), "Location\nA point on a map." },
    });
    const Kind = definer.kind(Location, .{
        .name = "location",
        .validate = struct {
            fn validate(value: Location, problems: *operation_define.Problems(Location)) void {
                if (value.lat < -90 or value.lat > 90) {
                    problems.add(.lat, "Must be between -90 and 90");
                }
            }
        }.validate,
        .text = struct {
            fn text(ctx: *plugin_context.PluginCtx, value: Location) Error![]const u8 {
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
