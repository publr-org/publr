//! A plugin's call into Publr in its own structs (`sdk/plugin/shape_wire.zig`). An operation
//! compiled into Publr takes its input read straight out of the plugin's memory into its own
//! `In`, and its `Out` is laid out straight into the layout the plugin described: no JSON in
//! between. The answer waits here for the room the plugin makes for it (`publr_shaped_take`),
//! so it lives in the plugin's own arena, freed with the call.
//!
//! Everything the plugin says is checked: where its request is, how long each part is, and
//! both descriptions (`described.zig`). A request that is wrong in any way ends that call with
//! an error; nothing outside the plugin's memory is read or written.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const call_json = @import("../../sdk/call_json.zig");
const transient_module = @import("transient.zig");
const invoke = @import("invoke.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const given_typed = @import("given_typed.zig");
const laid_module = @import("laid.zig");
const laid_typed = @import("laid_typed.zig");
const held_module = @import("held.zig");
const transfer = @import("transfer.zig");
const shaped_read = @import("shaped_read.zig");
const shaped_answer = @import("shaped_answer.zig");
const shaped_apply = @import("shaped_apply.zig");

const Described = described_module.Described;
const Given = given_module.Given;
const Laid = laid_module.Laid;

/// What holds an answer between the call and the plugin taking it.
const gpa = std.heap.c_allocator;

const name_bytes_max = shaped_read.name_bytes_max;
const description = shaped_read.description;
const table_of = shaped_read.table_of;
const copy = shaped_read.copy;
const hold = shaped_answer.hold;
const hold_text = shaped_answer.hold_text;
const sizes = shaped_answer.sizes;

pub const Pending = shaped_answer.Pending;
pub const publr_shaped_take = shaped_answer.publr_shaped_take;
pub const publr_answer = shaped_answer.publr_answer;
pub const hold_typed = shaped_answer.hold_typed;
pub const sent_json = shaped_read.sent_json;

/// What the plugin's `call` passes, copied out of its memory and checked.
const Asked = struct {
    name: []const u8,
    root: u32,
    sent: Described,
    table: []const shape_wire.Entry,
    wanted: Described,
};

/// `publr_call_shaped(call, sizes)`: runs the operation `call` (`shape_wire.Call`) names;
/// `sizes` gets how many bytes and side table entries its answer takes, which
/// `publr_shaped_take` then writes where the plugin made room. A refusal answers its name as
/// the block.
pub fn publr_call_shaped(env: *wasm.Env, call_ptr: u32, sizes_ptr: u32) callconv(.c) u32 {
    const invocation = invoke.invocation_of(env) orelse return wire.code_of(error.Unavailable);
    const ctx = invocation.ctx;

    std.debug.assert(invocation.loaded.name().len > 0);

    if (invocation.calls_left == 0) {
        return wire.code_of(error.Throttled);
    }

    invocation.calls_left -= 1;
    invocation.loaded.counted.host_calls += 1;

    const begun = call_json.host_call_begun(ctx);

    defer if (begun) |mark| {
        call_json.give_back(ctx, mark);
    };

    var parts: shape_wire.Call = undefined;

    if (!env.read(call_ptr, std.mem.asBytes(&parts))) {
        return wire.code_of(error.Invalid);
    }

    // The descriptions and what is read for a moment: never out of the request's own memory,
    // which holds only what the operation itself keeps.
    var working = std.heap.ArenaAllocator.init(gpa);
    defer working.deinit();

    const memory = working.allocator();
    const asked = asked_of(env, memory, parts) catch |err| return wire.code_of(err);
    var laid = answered(invocation, env, &asked, memory) catch |err| {
        if (err == error.Failed) if (ctx.failure) |failure| {
            hold_text(invocation, failure.name) catch return wire.code_of(error.OutOfMemory);
            _ = sizes(env, invocation, sizes_ptr);
        };

        return wire.code_of(err);
    };

    hold(invocation, &laid);

    return sizes(env, invocation, sizes_ptr);
}

/// What operation `asked.name` answers, laid out as the plugin described.
fn answered(
    invocation: *invoke.Invocation,
    env: *wasm.Env,
    asked: *const Asked,
    memory: std.mem.Allocator,
) sdk.Error!Laid {
    @setEvalBranchQuota(200_000);

    std.debug.assert(asked.name.len > 0);

    // An answer is a struct, or a value whose shape comes with the data (`call_value`).
    const wanted = asked.wanted.nodes[Described.root].kind;

    if (wanted != .object and wanted != .free) {
        return error.Invalid;
    }

    // The apply of modifiers keeps the plugin's values laid out the whole way.
    if (std.mem.eql(u8, asked.name, shaped_apply.name)) {
        return shaped_apply.answered(invocation, env, .{
            .described = &asked.sent,
            .root = asked.root,
            .table = asked.table,
        }, &asked.wanted, memory);
    }

    inline for (registry.SDK.operations) |Operation| {
        if (std.mem.eql(u8, Operation.name, asked.name)) {
            return compiled(Operation, invocation, env, asked, memory);
        }
    }

    return installed(invocation, env, asked, memory);
}

/// An operation compiled into Publr: its `In` read where the plugin's value lies, dispatched
/// as any call is (authorized, validated), its `Out` laid out from the struct.
fn compiled(
    comptime Operation: type,
    invocation: *invoke.Invocation,
    env: *wasm.Env,
    asked: *const Asked,
    memory: std.mem.Allocator,
) sdk.Error!Laid {
    const ctx = invocation.ctx;
    const loaded = invocation.loaded;

    std.debug.assert(loaded.name().len > 0);

    if (invoke.remote_off(loaded, ctx, Operation.name)) {
        return error.Unavailable;
    }

    // What the operation is given lives as long as its call: in the request's memory.
    var given: Given = .{
        .described = &asked.sent,
        .memory = .{
            .guest = env,
        },
        .arena = ctx.arena,
        .table = asked.table,
    };
    const window = try given.window(Described.root, asked.root);
    const in = try given_typed.read(Operation.In, &given, Described.root, window, .{
        .ignore_unknown = ctx.plugin_code,
        .absent = comptime absent_of(Operation.In),
    });

    // A transient plugin's own records live in the server's memory, never in the site.
    var held_ctx: sdk.Ctx = undefined;
    const target = if (loaded.transient) |held| blk: {
        if (!transient_module.own_record(loaded.own_types, Operation.name, type_of(in))) {
            break :blk ctx;
        }

        held_ctx = held.context_of(ctx);
        break :blk &held_ctx;
    } else ctx;
    const out = try registry.SDK.dispatch(target, Operation, in);
    var laid: Laid = .{};
    errdefer laid.deinit(gpa);

    var layout: laid_module.Layout = .{
        .gpa = gpa,
        .scratch = memory,
        .described = &asked.wanted,
        .laid = &laid,
    };

    try layout.begin();
    try laid_typed.lay(Operation.Out, &layout, Described.root, &out, 0);

    return laid;
}

/// How an optional holding nothing is written into what `In` keeps as JSON: left out, or
/// `null` for an operation that says a `null` clears (`pub const absent_is_null = true`).
fn absent_of(comptime In: type) given_module.Absent {
    comptime {
        std.debug.assert(@typeInfo(In) == .@"struct");

        if (@hasDecl(In, "absent_is_null") and In.absent_is_null) {
            return .null;
        }

        return .left_out;
    }
}

/// The content type an input names, by the convention every operation follows: `type`.
fn type_of(in: anytype) ?[]const u8 {
    const In = @TypeOf(in);

    comptime std.debug.assert(@typeInfo(In) == .@"struct");

    if (comptime !@hasField(In, "type")) {
        return null;
    }

    return switch (@FieldType(In, "type")) {
        []const u8, ?[]const u8 => in.type,
        else => null,
    };
}

/// An operation another installed plugin owns: the request is copied whole out of this
/// plugin's memory and handed on as it is, and the answer that plugin handed back is moved
/// into the layout this one described. No JSON in between.
fn installed(
    invocation: *invoke.Invocation,
    env: *wasm.Env,
    asked: *const Asked,
    memory: std.mem.Allocator,
) sdk.Error!Laid {
    const ctx = invocation.ctx;
    var given: Given = .{
        .described = &asked.sent,
        .memory = .{
            .guest = env,
        },
        .arena = memory,
        .table = asked.table,
    };
    const name = ctx.arena.dupe(u8, asked.name) catch return error.OutOfMemory;

    if (invoke.remote_off(invocation.loaded, ctx, name)) {
        return error.Unavailable;
    }

    const piece = try held_module.keep(memory, memory, &given, asked.root);
    const answer = try registry.SDK.call_passed(ctx, name, .{
        .laid = piece,
    });

    std.debug.assert(answer.bytes().len > 0);

    switch (answer) {
        .json => |text| return laid_module.from_json(gpa, memory, &asked.wanted, text),
        .laid => |handed| return moved(handed, &asked.wanted, memory),
    }
}

/// What a plugin handed back, built in the layout `wanted` says.
fn moved(piece: []const u8, wanted: *const Described, memory: std.mem.Allocator) sdk.Error!Laid {
    const held = try held_module.open(memory, piece);
    var reading = held.given(memory);
    var laid: Laid = .{};
    errdefer laid.deinit(gpa);

    var layout: laid_module.Layout = .{
        .gpa = gpa,
        .scratch = memory,
        .described = wanted,
        .laid = &laid,
    };

    std.debug.assert(wanted.nodes.len > 0);

    try layout.begin();
    try transfer.move(&layout, Described.root, 0, &reading, Described.root, try held.window(
        &reading,
    ));

    return laid;
}

fn asked_of(
    env: *wasm.Env,
    arena: std.mem.Allocator,
    parts: shape_wire.Call,
) given_module.Error!Asked {
    if (parts.name_len == 0 or parts.name_len > name_bytes_max) {
        return error.Invalid;
    }

    const name = try copy(env, arena, parts.name, parts.name_len);
    const sent = try description(env, arena, parts.asked, parts.asked_len);
    const wanted = try description(env, arena, parts.answer, parts.answer_len);

    std.debug.assert(name.len > 0);

    return .{
        .name = name,
        .root = parts.root,
        .sent = sent,
        .table = try table_of(env, arena, parts.table, parts.table_len),
        .wanted = wanted,
    };
}
