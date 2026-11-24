//! A plugin's `ctx.mod`: its call of `mod.apply` in its own structs (`shaped_call.zig`).
//! The values are copied out of its memory once, held laid out through every modifier
//! (`applied.zig`), and laid back in the layout the plugin described for the answer. The
//! operation runs as any call does, authorized and counted; the values never become its
//! JSON.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const operations = @import("../../operations/mod.zig");
const invoke = @import("invoke.zig");
const applied = @import("applied.zig");
const described_module = @import("described.zig");
const given_module = @import("given.zig");
const laid_module = @import("laid.zig");
const transfer = @import("transfer.zig");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");

const Described = described_module.Described;
const Given = given_module.Given;
const Laid = laid_module.Laid;

/// What holds an answer between the call and the plugin taking it.
const gpa = std.heap.c_allocator;

pub const name = sdk.mods.Apply.name;

/// What the plugin sent, as its `ctx.mod` lays it out: the name, and the values.
pub const Sent = struct {
    described: *const Described,
    root: u32,
    table: []const shape_wire.Entry,
};

/// The values at `sent` through every modifier of the name it gives, laid out as `wanted`
/// says: a struct whose `values` takes them. `memory` holds what is read for a moment.
pub fn answered(
    invocation: *invoke.Invocation,
    env: *wasm.Env,
    sent: Sent,
    wanted: *const Described,
    memory: std.mem.Allocator,
) sdk.Error!Laid {
    const ctx = invocation.ctx;
    var given: Given = .{
        .described = sent.described,
        .memory = .{
            .guest = env,
        },
        .arena = memory,
        .table = sent.table,
    };

    if (invoke.remote_off(invocation.loaded, ctx, name)) {
        return error.Unavailable;
    }

    if (sent.described.nodes[Described.root].kind != .object) {
        return error.Invalid;
    }

    const window = try given.window(Described.root, sent.root);
    const named = try field_of(sent.described, "name", .text);
    const values = try field_of(sent.described, "values", .list);
    const applied_as = try given.text(window[named.offset..]);
    // Built in the moment's memory; only the piece itself is kept in the call's.
    const copied = try applied.from_given(memory, &given, values.node, window[values.offset..]);
    var held: []const u8 = ctx.arena.dupe(u8, copied) catch return error.OutOfMemory;
    const outer = ctx.applying;

    ctx.applying = &held;
    defer ctx.applying = outer;

    _ = try registry.SDK.dispatch(ctx, operations.Apply, .{
        .name = try ctx.arena.dupe(u8, applied_as),
        .values = .{
            .text = "[]",
        },
    });

    std.debug.assert(held.len > 0);

    return laid_back(held, wanted, memory);
}

/// The field `field_name` of the root of what the plugin sent, which must be of `kind`.
fn field_of(
    described: *const Described,
    comptime field_name: []const u8,
    kind: described_module.Kind,
) sdk.Error!described_module.Field {
    std.debug.assert(described.nodes[Described.root].kind == .object);

    const index = described.field_named(Described.root, field_name, 0) orelse {
        return error.Invalid;
    };
    const found = described.fields_of(Described.root)[index];

    if (described.nodes[found.node].kind != kind) {
        return error.Invalid;
    }

    return found;
}

/// The values `held` holds, built as the `values` of the answer the plugin described.
fn laid_back(held: []const u8, wanted: *const Described, memory: std.mem.Allocator) sdk.Error!Laid {
    var standing: applied.Opened = undefined;
    var laid: Laid = .{};
    errdefer laid.deinit(gpa);

    var layout: laid_module.Layout = .{
        .gpa = gpa,
        .scratch = memory,
        .described = wanted,
        .laid = &laid,
    };

    if (wanted.nodes[Described.root].kind != .object) {
        return error.Invalid;
    }

    try standing.init(memory, held);
    try layout.begin();

    for (wanted.fields_of(Described.root)) |field| {
        if (!std.mem.eql(u8, field.name, "values")) {
            try layout.left_out(field, field.offset);
            continue;
        }

        const window = try standing.held.window(&standing.reading);

        try transfer.move(
            &layout,
            field.node,
            field.offset,
            &standing.reading,
            standing.list,
            window[standing.offset..],
        );
    }

    std.debug.assert(laid.block.items.len > 0);

    return laid;
}
