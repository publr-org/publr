//! `Publr.t`, `Publr.tn` and `Publr.tx` in a template's script: the message in the page's
//! language through the same runtime the components translate with, or the source text
//! where the page has no catalogue.
const std = @import("std");
const runtime = @import("runtime");
const engine = @import("vm.zig");

const VM = engine.VM;
const Value = engine.Value;
const api = engine.api;

/// How many `{name}` values one message fills.
pub const values_max: u32 = 32;

/// `[context, id, plural, count, counted, values]`, as the runtime's `t`, `tn`, `tx` pass it.
pub fn translated(vm: *VM, ctx: anytype, args: Value) !Value {
    std.debug.assert(api.JS_IsArray(args));

    const context = try text_at(vm, args, 0);
    const id = try text_at(vm, args, 1);
    const plural = try text_at(vm, args, 2);
    const counted = try boolean_at(vm, args, 4);
    const count: ?f64 = if (counted) try number_at(vm, args, 3) else null;
    const values = try values_of(vm, try text_at(vm, args, 5));
    const translator = if (@hasDecl(@TypeOf(ctx.*), "language"))
        (try ctx.language()).translator
    else
        null;

    if (id.len == 0) {
        return error.EmptyMessage;
    }

    return vm.string(try runtime.translate(vm.arena, translator, .{
        .context = context,
        .id = id,
        .plural = plural,
        .count = count,
        .values = values,
    }));
}

fn values_of(vm: *VM, json: []const u8) ![]const runtime.Placeholder {
    std.debug.assert(json.len > 0);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, vm.arena, json, .{});

    if (parsed != .object) {
        return error.InvalidMessageValues;
    }

    if (parsed.object.count() > values_max) {
        return error.TooManyMessageValues;
    }

    const out = try vm.arena.alloc(runtime.Placeholder, parsed.object.count());
    var iterator = parsed.object.iterator();
    var index: u32 = 0;

    while (iterator.next()) |entry| : (index += 1) {
        out[index] = .{
            .name = entry.key_ptr.*,
            .value = try written(vm.arena, entry.value_ptr.*),
        };
    }

    std.debug.assert(index == out.len);

    return out;
}

fn written(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    std.debug.assert(@intFromEnum(value) <= @intFromEnum(std.json.Value.object));

    return switch (value) {
        .string => |text| text,
        .integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .float => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .bool => |flag| if (flag) "true" else "false",
        else => "",
    };
}

fn text_at(vm: *VM, args: Value, index: u32) ![]const u8 {
    std.debug.assert(api.JS_IsArray(args));

    const value = try vm.item(args, index);
    defer vm.free(value);

    if (!api.JS_IsString(value)) {
        return error.ExpectedString;
    }

    return vm.text(value);
}

fn number_at(vm: *VM, args: Value, index: u32) !f64 {
    std.debug.assert(api.JS_IsArray(args));

    const value = try vm.item(args, index);
    defer vm.free(value);
    var number: f64 = 0;

    if (!api.JS_IsNumber(value) or api.JS_ToFloat64(vm.context, &number, value) < 0) {
        return error.ExpectedNumber;
    }

    return number;
}

fn boolean_at(vm: *VM, args: Value, index: u32) !bool {
    std.debug.assert(api.JS_IsArray(args));

    const value = try vm.item(args, index);
    defer vm.free(value);

    return api.JS_ToBool(vm.context, value) == 1;
}
