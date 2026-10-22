//! `publr.field.kind(Value, .{ .name, .validate, .text, .icon })`: a field kind a plugin
//! brings. Its storage follows `Value` (text, a whole number, a number, yes or no, or a struct
//! kept as JSON), its words are the `///` on `Value`, `.validate` runs on every write with
//! the same `problems` as an operation's, and `.text` (`fn (ctx, value) Error![]const u8`)
//! is how a value reads in list cells, search and on the site.
const std = @import("std");
const kinds = @import("../../model/kinds.zig");
const field_model = @import("../../model/field.zig");
const plugin_define = @import("define.zig");
const operation_define = @import("operation_define.zig");
const sdk = @import("../../sdk.zig");
const plugin_context = @import("context.zig");

const option_names = [_][]const u8{ "name", "validate", "text", "editor", "icon" };

pub fn kind(comptime Value: type, comptime options: anytype) type {
    comptime {
        const Options = @TypeOf(options);

        for (std.meta.fieldNames(Options)) |given| {
            if (!listed(given)) {
                @compileError("field kind " ++ options.name ++ ": no option `" ++ given ++ "`");
            }
        }

        if (@hasField(Options, "editor")) {
            @compileError("field kind " ++ options.name ++ ": editors come with views in the " ++
                "plugin frame; until then the form shows the value as JSON");
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
        const texted = @hasField(@TypeOf(options), "text") and plugin_context.Mode.native ==
            @import("guest.zig").mode;

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
fn decoded(comptime Value: type, arena: std.mem.Allocator, value: std.json.Value) !Value {
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
        fn text(ctx: *anyopaque, value: std.json.Value) ?[]const u8 {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
            const parsed = decoded(Definition.Shape, inner.arena, value);
            var wrapped: plugin_context.PluginCtx = .{
                .inner = inner,
            };

            std.debug.assert(inner.now_ms >= 0);

            return Definition.given.text(&wrapped, parsed catch return null) catch null;
        }
    };
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

    try std.testing.expectEqualStrings("52.5, 21", declared.text.?(&ctx, stored).?);
    try std.testing.expect(declared.text.?(&ctx, .{
        .string = "not a place",
    }) == null);
}
