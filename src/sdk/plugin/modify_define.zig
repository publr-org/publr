//! `publr.modify("variant.title", title)`: a plugin changes a value wherever its owner applies
//! it (`ctx.mod`), shown or saved. `run` takes one value, typed by its parameter, and changes
//! it in place; the batch runs through it in passes, its reads collected and read together
//! between them (`filter_reads.zig`). Pure: no writes, no outside calls; a value whose
//! modifier fails, or that does not read as its type, stays as it was.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const mods = @import("../mods.zig");
const filter_reads = @import("filter_reads.zig");

/// A record's title as core applies it, `<type>.title`: the record's id, its fields typed, and
/// the title a modifier changes.
pub fn Title(comptime Doc: type) type {
    return struct {
        id: []const u8,
        title: []const u8,
        record: Doc,
    };
}

/// The value a modifier's `run` takes: its second parameter, by pointer.
pub fn ValueOf(comptime run: anytype) type {
    comptime {
        const params = @typeInfo(@TypeOf(run)).@"fn".params;

        if (params.len != 2 or @typeInfo(params[1].type.?) != .pointer) {
            @compileError("a modifier is `fn (ctx: *publr.Ctx, value: *Value) publr.Error!void`");
        }

        return @typeInfo(params[1].type.?).pointer.child;
    }
}

pub fn check_name(comptime name: []const u8) void {
    comptime {
        if (!mods.valid(name, true)) {
            @compileError("`" ++ name ++ "` is no mod name: dotted parts of a-z, 0-9 and _, " ++
                "`*` for one whole part");
        }
    }
}

/// Runs `run` over the batch: a pass over every item still waiting, then their noted reads
/// together, at most `rounds_max` times. Each item read as `Value`, changed, and written back.
pub fn run_batch(
    comptime Value: type,
    comptime run: anytype,
    ctx: anytype,
    batch: *mods.Batch,
) sdk.Error!void {
    std.debug.assert(batch.items.len <= mods.items_max);
    std.debug.assert(ctx.reads == null);

    const memory = ctx.arena();
    var reads: filter_reads.Reads = .{
        .arena = memory,
    };
    const values = memory.alloc(?Value, batch.items.len) catch return error.OutOfMemory;
    const done = memory.alloc(bool, batch.items.len) catch return error.OutOfMemory;

    for (batch.items, values, done) |item, *value, *finished| {
        value.* = std.json.parseFromValueLeaky(Value, memory, item, .{
            .ignore_unknown_fields = true,
        }) catch null;
        finished.* = value.* == null;
    }

    for (0..filter_reads.rounds_max) |_| {
        ctx.reads = &reads;

        const waiting = pass(Value, run, ctx, values, done);

        ctx.reads = null;

        if (!waiting) {
            break;
        }

        try reads.settle(ctx);
    }

    for (batch.items, values) |*item, value| {
        const changed = value orelse continue;
        const text = std.json.Stringify.valueAlloc(memory, changed, .{}) catch {
            return error.OutOfMemory;
        };

        item.* = std.json.parseFromSliceLeaky(std.json.Value, memory, text, .{
            .allocate = .alloc_always,
        }) catch continue;
    }
}

/// One pass: each waiting value through `run`; whether any asked for a read not in yet. A
/// value whose `run` fails goes back to what it was.
fn pass(
    comptime Value: type,
    comptime run: anytype,
    ctx: anytype,
    values: []?Value,
    done: []bool,
) bool {
    std.debug.assert(values.len == done.len);
    std.debug.assert(values.len <= mods.items_max);

    var waiting = false;

    for (values, done) |*value, *finished| {
        if (finished.*) {
            continue;
        }

        var changed = value.*.?;

        run(ctx, &changed) catch |err| {
            if (err == error.NotYet) {
                waiting = true;
            } else {
                finished.* = true;
            }

            continue;
        };

        value.* = changed;
        finished.* = true;
    }

    return waiting;
}

const Tea = struct {
    id: []const u8,
    title: []const u8,
    record: struct {
        product: []const u8,
    },
};

test "a modifier written for one value: its reads wait for the batch, then come together" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const memory = arena_state.allocator();
    const Fake = struct {
        reads: ?*filter_reads.Reads = null,
        memory: std.mem.Allocator,
        lists: u32 = 0,

        pub fn arena(self: *const @This()) std.mem.Allocator {
            return self.memory;
        }

        pub fn call_json(self: *@This(), name: []const u8, _: []const u8) sdk.Error![]const u8 {
            std.debug.assert(name.len > 0);

            self.lists += 1;

            return error.NotFound;
        }
    };
    var fake: Fake = .{
        .memory = memory,
    };
    const Modifier = struct {
        fn run(ctx: *Fake, tea: *Tea) sdk.Error!void {
            std.debug.assert(tea.id.len > 0);

            _ = ctx.reads.?.answer(u8, "record.query", .{
                .id = tea.record.product,
            }) catch |err| switch (err) {
                error.NotFound => 0,
                else => return err,
            };

            tea.title = try std.fmt.allocPrint(ctx.memory, "{s}, {s}", .{
                tea.record.product,
                tea.title,
            });
        }
    };
    const text = "[{\"id\":\"a\",\"title\":\"50 g\",\"record\":{\"product\":\"Earl Grey\"}}," ++
        "{\"id\":\"b\",\"title\":\"50 g\",\"record\":{\"product\":\"Darjeeling\"}},{\"x\":1}]";
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, memory, text, .{});
    var batch: mods.Batch = .{
        .items = parsed.array.items,
    };

    try run_batch(Tea, Modifier.run, &fake, &batch);
    const first = batch.items[0].object.get("title").?.string;
    const second = batch.items[1].object.get("title").?.string;

    try std.testing.expectEqualStrings("Earl Grey, 50 g", first);
    try std.testing.expectEqualStrings("Darjeeling, 50 g", second);
    try std.testing.expect(batch.items[2].object.get("title") == null);
    try std.testing.expectEqual(@as(u32, 2), fake.lists);
}
