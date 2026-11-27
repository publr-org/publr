//! How an installed plugin's module keeps the reads a modifier notes (`mod_reads.zig`):
//! what was asked stays the struct it is, the question goes to Publr laid out, and the
//! answer is kept as the struct Publr laid out. A read is told from another by its input's
//! bytes (`laid_key.zig`); no text and no free-form value is built for it.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const record = @import("../../operations/record.zig");
const laid_key = @import("laid_key.zig");
const mod_reads = @import("mod_reads.zig");
const guest = @import("guest.zig");

const Error = @import("../../publr/operation.zig").Error;
const Entry = mod_reads.Entry;
const Reads = mod_reads.Reads;

/// What an entry keeps beside its key: its input and answer as the structs they are.
pub const Held = struct {
    asked: ?*const anyopaque = null,
    out: ?*const anyopaque = null,
    /// The types the two are, by name: an answer is only ever read as what it was kept as.
    asked_as: []const u8 = "",
    out_as: []const u8 = "",
    ask: ?*const fn (api: *guest.SandboxApi, arena: std.mem.Allocator, entry: *Entry) Error!void =
        null,
};

pub fn key(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}![]const u8 {
    return laid_key.of(arena, value);
}

/// `in` kept as it is, with the call that asks it and keeps the answer as an `Out`.
pub fn note(arena: std.mem.Allocator, comptime Out: type, in: anytype) error{OutOfMemory}!Held {
    const In = @TypeOf(in);
    const asked = try arena.create(In);
    const Asking = struct {
        fn ask(api: *guest.SandboxApi, memory: std.mem.Allocator, entry: *Entry) Error!void {
            const given: *const In = @ptrCast(@alignCast(entry.held.asked.?));
            const out = memory.create(Out) catch return error.OutOfMemory;

            std.debug.assert(entry.name.len > 0);

            out.* = try api.call_shaped(In, Out, entry.name, given);
            entry.held.out = out;
        }
    };

    asked.* = in;

    std.debug.assert(@typeName(Out).len > 0);

    return .{
        .asked = asked,
        .asked_as = @typeName(In),
        .out_as = @typeName(Out),
        .ask = &Asking.ask,
    };
}

pub fn same(entry: *const Entry, comptime Out: type) bool {
    std.debug.assert(entry.held.out_as.len > 0);

    return entry.held.out_as.ptr == @typeName(Out).ptr or
        std.mem.eql(u8, entry.held.out_as, @typeName(Out));
}

pub fn answered(entry: *const Entry) bool {
    return entry.held.out != null;
}

pub fn read(comptime Out: type, arena: std.mem.Allocator, entry: *const Entry) Error!Out {
    _ = arena;

    std.debug.assert(same(entry, Out));

    const out: *const Out = @ptrCast(@alignCast(entry.held.out orelse return error.NotYet));

    return out.*;
}

pub fn ask(api: *guest.SandboxApi, arena: std.mem.Allocator, entry: *Entry) Error!void {
    std.debug.assert(entry.held.ask != null);

    return entry.held.ask.?(api, arena, entry);
}

/// The plain `record.get`s noted, read together in one `record.list`; a list that fails
/// leaves each get to be read on its own.
pub fn gets(reads: *Reads, api: *guest.SandboxApi) Error!void {
    var ids: std.ArrayList([]const u8) = .empty;
    var found: std.ArrayList(*Entry) = .empty;

    for (reads.entries.items) |*entry| {
        const id = plain_get(entry) orelse continue;

        ids.append(reads.arena, id) catch return error.OutOfMemory;
        found.append(reads.arena, entry) catch return error.OutOfMemory;
    }

    if (ids.items.len == 0) {
        return;
    }

    std.debug.assert(ids.items.len <= record.list_max);

    const asked: record.List.In = .{
        .ids = ids.items,
        .limit = @intCast(ids.items.len),
        .documents = true,
        .expand = false,
        .purpose = .edit,
    };
    const List = record.List;
    const listed = api.call_shaped(List.In, List.Out, List.name, &asked) catch return;

    if (listed.documents.len != listed.records.len) {
        return error.Invalid;
    }

    for (found.items, ids.items) |entry, id| {
        const got = mod_reads.got_of(listed, id) orelse continue;
        const out = reads.arena.create(record.Get.Out) catch return error.OutOfMemory;

        out.* = got;
        entry.held.out = out;
    }
}

/// The id of a noted `record.get` that asks for the record as stored and is read as the
/// operation's own answer: what a list of ids reads too.
fn plain_get(entry: *const Entry) ?[]const u8 {
    std.debug.assert(entry.name.len > 0);

    if (entry.settled() or !std.mem.eql(u8, entry.name, record.Get.name)) {
        return null;
    }

    const typed = std.mem.eql(u8, entry.held.asked_as, @typeName(record.Get.In)) and
        std.mem.eql(u8, entry.held.out_as, @typeName(record.Get.Out));

    if (!typed) {
        return null;
    }

    const in: *const record.Get.In = @ptrCast(@alignCast(entry.held.asked.?));

    return if (mod_reads.plain(in.*)) in.id else null;
}
