//! What a modifier reads while it runs over a batch. The first pass only notes each read and
//! answers `error.NotYet`; `settle` then reads what was noted, and the next pass is answered
//! from it. A record's handle notes a `get` by its type (`Typed`): every id of one type is
//! read in one call, laid out as the record's own struct. Any other read is noted by its
//! input: the plain `record.get`s together in one `record.list`, the rest once per distinct
//! input.
//!
//! A read is noted and its answer kept in the form the build talks to Publr in: an installed
//! plugin's module keeps its own structs, asked and answered laid out, and never writes or
//! parses text or a free-form value (`mod_reads_laid.zig`); a plugin compiled in keeps
//! core's own JSON.
const std = @import("std");
const json_form = @import("../operation/json.zig");
const id_map = @import("../../publr/plugin/id_map.zig");
const sdk = @import("../../sdk.zig");
const record = @import("../../operations/record.zig");

const Error = @import("../../publr/operation.zig").Error;

/// A read that depends on a read takes another round; past this the item stays as it was.
pub const rounds_max: u32 = 4;
pub const entries_max: u32 = 512;

/// How a noted read and its answer are kept, and how one is asked of Publr: an installed
/// plugin's as its own structs (`mod_reads_laid.zig`), a compiled-in one's as core's JSON.
const kept = if (json_form.sandboxed) @import("mod_reads_laid.zig") else struct {
    const wire_json = @import("wire_json.zig");

    pub const Held = struct {};

    pub fn key(arena: std.mem.Allocator, value: anytype) error{OutOfMemory}![]const u8 {
        return wire_json.stringify(arena, value);
    }

    pub fn note(
        arena: std.mem.Allocator,
        comptime Out: type,
        in: anytype,
    ) error{OutOfMemory}!Held {
        _ = arena;
        _ = Out;
        _ = in;

        return .{};
    }

    pub fn same(entry: *const Entry, comptime Out: type) bool {
        _ = entry;
        _ = Out;

        return true;
    }

    pub fn answered(entry: *const Entry) bool {
        return entry.answer != null;
    }

    pub fn read(comptime Out: type, arena: std.mem.Allocator, entry: *const Entry) Error!Out {
        const text = entry.answer orelse return error.NotYet;

        return decode(Out, arena, text) catch error.Invalid;
    }

    fn decode(comptime Shape: type, arena: std.mem.Allocator, bytes: []const u8) !Shape {
        return wire_json.parse(Shape, arena, bytes, .{});
    }

    pub fn ask(api: anytype, arena: std.mem.Allocator, entry: *Entry) Error!void {
        _ = arena;

        entry.answer = api.call_json(entry.name, entry.input) catch |err| {
            return @import("../operation.zig").public_of(err);
        };
    }

    /// The plain `record.get`s noted, read together in one `record.list`; a list that
    /// fails leaves each get to be read on its own.
    pub fn gets(reads: *Reads, api: anytype) Error!void {
        var ids: std.ArrayList([]const u8) = .empty;
        var found: std.ArrayList(*Entry) = .empty;

        for (reads.entries.items) |*entry| {
            const id = plain_get(reads.arena, entry) orelse continue;

            ids.append(reads.arena, id) catch return error.OutOfMemory;
            found.append(reads.arena, entry) catch return error.OutOfMemory;
        }

        if (ids.items.len == 0) {
            return;
        }

        std.debug.assert(ids.items.len <= record.list_max);

        const input = try key(reads.arena, record.List.In{
            .ids = ids.items,
            .limit = @intCast(ids.items.len),
            .documents = true,
            .expand = false,
            .purpose = .edit,
        });
        const text = api.call_json(record.List.name, input) catch return;
        const listed = decode(record.List.Out, reads.arena, text) catch {
            return error.Invalid;
        };

        for (found.items, ids.items) |entry, id| {
            const got = got_of(listed, id) orelse continue;

            entry.answer = try key(reads.arena, got);
        }
    }

    /// The id of a noted `record.get` that asks for the record as stored, as a typed
    /// handle reads it and a list of ids can too.
    fn plain_get(arena: std.mem.Allocator, entry: *const Entry) ?[]const u8 {
        std.debug.assert(entry.name.len > 0);

        if (entry.settled() or !std.mem.eql(u8, entry.name, record.Get.name)) {
            return null;
        }

        const in = decode(record.Get.In, arena, entry.input) catch return null;

        return if (plain(in)) in.id else null;
    }
};

/// Whether a `record.get` asks for the record as stored: what a list of ids reads too.
pub fn plain(in: record.Get.In) bool {
    const stored = in.purpose == .edit and in.slot == null and in.dimensions.pairs.len == 0;

    std.debug.assert(in.id.len <= 1 << 16);

    return stored and in.id.len > 0;
}

/// What `record.get` answers for `id`, from a list that read it; null when it did not.
pub fn got_of(listed: record.List.Out, id: []const u8) ?record.Get.Out {
    std.debug.assert(id.len > 0);
    std.debug.assert(listed.documents.len == listed.records.len);

    for (listed.records, listed.documents) |row, document| {
        if (std.mem.eql(u8, row.id, id)) {
            return .{
                .record = row,
                .slot = "live",
                .document = document,
            };
        }
    }

    return null;
}

pub const Entry = struct {
    name: []const u8,
    /// What was asked, as bytes that are the same for the same input.
    input: []const u8,
    answer: ?[]const u8 = null,
    failed: ?Error = null,
    held: kept.Held = .{},

    pub fn settled(entry: *const Entry) bool {
        return kept.answered(entry) or entry.failed != null;
    }
};

/// How many record types one batch reads by id.
pub const types_max: u32 = 64;

/// The records of one type a modifier reads by id over a batch: the ids are noted on the
/// first pass, read together in one call laid out as the plugin's own struct, and answered
/// from here on the next. No answer is written or read as a free-form value on the way.
/// The record's handle owns what `items` holds and how they are read (`settle`).
pub const Typed = struct {
    /// The record type, as the handle names it.
    key: []const u8,
    ids: std.ArrayList([]const u8) = .empty,
    /// How many of `ids` were read already.
    asked: u32 = 0,
    /// Where each id read is among the handle's items, or how its read failed.
    found: id_map.Map(Answer) = .empty,
    noted: id_map.Map(void) = .empty,
    /// The handle's own list of the records read.
    items: ?*anyopaque = null,
    /// The plugin's context the handle reads through, as the handle keeps it.
    reader: ?*anyopaque = null,
    /// Reads `ids[asked..]` and keeps them.
    settle: *const fn (typed: *Typed, arena: std.mem.Allocator) Error!void,

    pub const Answer = union(enum) {
        at: u32,
        failed: Error,
    };

    /// Where the record `id` is among the items read; `error.NotYet` with the id noted when
    /// it was not read yet, or the error its read ended with.
    pub fn where(typed: *Typed, arena: std.mem.Allocator, id: []const u8) Error!u32 {
        std.debug.assert(id.len > 0);
        std.debug.assert(typed.asked <= typed.ids.items.len);

        if (typed.found.get(id)) |answer| {
            return switch (answer) {
                .at => |index| index,
                .failed => |err| err,
            };
        }

        if (!typed.noted.contains(id)) {
            if (typed.ids.items.len >= entries_max) {
                return error.Invalid;
            }

            const kept_id = arena.dupe(u8, id) catch return error.OutOfMemory;

            typed.ids.append(arena, kept_id) catch return error.OutOfMemory;
            typed.noted.put(arena, kept_id, {}) catch return error.OutOfMemory;
        }

        return error.NotYet;
    }

    /// The ids noted and not read yet.
    pub fn pending(typed: *const Typed) []const []const u8 {
        std.debug.assert(typed.asked <= typed.ids.items.len);

        return typed.ids.items[typed.asked..];
    }
};

pub const Reads = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    typed: std.ArrayList(*Typed) = .empty,

    /// The batch of record type `key`, made with `settle` the first time it is asked for.
    pub fn typed_of(
        self: *Reads,
        key: []const u8,
        settle_with: *const fn (*Typed, std.mem.Allocator) Error!void,
    ) Error!*Typed {
        std.debug.assert(key.len > 0);
        std.debug.assert(self.typed.items.len <= types_max);

        for (self.typed.items) |held| {
            if (held.key.ptr == key.ptr or std.mem.eql(u8, held.key, key)) {
                return held;
            }
        }

        if (self.typed.items.len == types_max) {
            return error.Invalid;
        }

        const made = self.arena.create(Typed) catch return error.OutOfMemory;

        made.* = .{
            .key = key,
            .settle = settle_with,
        };
        self.typed.append(self.arena, made) catch return error.OutOfMemory;

        return made;
    }

    /// The answer kept for this call, or a note of it and `error.NotYet`.
    pub fn answer(
        self: *Reads,
        comptime Out: type,
        name: []const u8,
        in: anytype,
    ) Error!Out {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.entries.items.len <= entries_max);

        const input = kept.key(self.arena, in) catch {
            return error.OutOfMemory;
        };

        for (self.entries.items) |*entry| {
            const same = std.mem.eql(u8, entry.name, name) and
                std.mem.eql(u8, entry.input, input) and kept.same(entry, Out);

            if (!same) {
                continue;
            }

            if (entry.failed) |err| {
                return err;
            }

            return kept.read(Out, self.arena, entry);
        }

        if (self.entries.items.len == entries_max) {
            return error.Invalid;
        }

        self.entries.append(self.arena, .{
            .name = name,
            .input = input,
            .held = try kept.note(self.arena, Out, in),
        }) catch return error.OutOfMemory;

        return error.NotYet;
    }

    /// Whether a read is noted and not answered yet.
    pub fn waiting(self: *const Reads) bool {
        std.debug.assert(self.entries.items.len <= entries_max);

        for (self.typed.items) |held| {
            if (held.pending().len > 0) {
                return true;
            }
        }

        for (self.entries.items) |*entry| {
            if (!entry.settled()) {
                return true;
            }
        }

        return false;
    }

    /// Answers every noted read through `api`: the plain `record.get`s together in
    /// one `record.list`, anything else once each, and so is a get the list did not reach (a
    /// plugin's list reaches only the types its grant names).
    pub fn settle(self: *Reads, ctx: anytype) Error!void {
        const api = @import("context.zig").behind_of(ctx);

        std.debug.assert(self.entries.items.len <= entries_max);

        for (self.typed.items) |held| {
            if (held.pending().len > 0) {
                try held.settle(held, self.arena);
            }

            std.debug.assert(held.pending().len == 0);
        }

        try kept.gets(self, api);

        for (self.entries.items) |*entry| {
            if (entry.settled()) {
                continue;
            }

            kept.ask(api, self.arena, entry) catch |err| {
                entry.failed = err;
            };
        }

        std.debug.assert(!self.waiting());
    }
};

const Fake = struct {
    calls: u32 = 0,
    arena: std.mem.Allocator,

    pub fn call_json(self: *Fake, name: []const u8, input: []const u8) Error![]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(input.len > 0);

        self.calls += 1;

        if (std.mem.eql(u8, name, record.List.name)) {
            return
            \\{"records":[{"id":"p1","type_id":"t1","type":"product","status":"published",
            \\"changed":false,"version":1,"title":"Earl Grey","slug":null,"created_by":null,
            \\"updated_by":null,"created_at":0,"updated_at":0}],
            \\"documents":["{\"title\":\"Earl Grey\"}"]}
            ;
        }

        return error.Denied;
    }
};

test "gets wait for the batch, then come from one list; one it misses is read on its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var reads: Reads = .{
        .arena = arena,
    };
    var fake: Fake = .{
        .arena = arena,
    };

    const first = reads.answer(record.Get.Out, record.Get.name, record.Get.In{
        .id = "p1",
        .purpose = .edit,
    });
    const second = reads.answer(record.Get.Out, record.Get.name, record.Get.In{
        .id = "p2",
        .purpose = .edit,
    });
    const other = reads.answer(record.List.Out, "record.query", .{
        .q = "x",
    });

    try std.testing.expectError(error.NotYet, first);
    try std.testing.expectError(error.NotYet, second);
    try std.testing.expectError(error.NotYet, other);
    try std.testing.expect(reads.waiting());

    try reads.settle(&fake);
    try std.testing.expectEqual(@as(u32, 3), fake.calls);
    try std.testing.expect(!reads.waiting());

    const got = try reads.answer(record.Get.Out, record.Get.name, record.Get.In{
        .id = "p1",
        .purpose = .edit,
    });

    try std.testing.expectEqualStrings("p1", got.record.id);
    try std.testing.expectError(error.Denied, reads.answer(
        record.Get.Out,
        record.Get.name,
        record.Get.In{
            .id = "p2",
            .purpose = .edit,
        },
    ));
    try std.testing.expectError(error.Denied, reads.answer(record.List.Out, "record.query", .{
        .q = "x",
    }));
}

test "ids of one type are noted once, read together, and answered by where they are" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var reads: Reads = .{
        .arena = arena,
    };
    const Probe = struct {
        fn settle(typed: *Typed, memory: std.mem.Allocator) Error!void {
            const calls: *u32 = @ptrCast(@alignCast(typed.reader.?));

            std.debug.assert(typed.pending().len > 0);

            calls.* += 1;

            // The first id is there, the second is not.
            for (typed.pending(), 0..) |id, place| {
                try typed.found.put(memory, id, if (place == 0) .{
                    .at = 7,
                } else .{
                    .failed = error.NotFound,
                });
            }

            typed.asked = @intCast(typed.ids.items.len);
        }
    };
    var calls: u32 = 0;
    const typed = try reads.typed_of("shop.item", &Probe.settle);

    typed.reader = &calls;
    try std.testing.expectError(error.NotYet, typed.where(arena, "a"));
    try std.testing.expectError(error.NotYet, typed.where(arena, "b"));
    try std.testing.expectError(error.NotYet, typed.where(arena, "a"));
    try std.testing.expectEqual(@as(usize, 2), typed.ids.items.len);
    try std.testing.expect(reads.waiting());

    var fake: Fake = .{
        .arena = arena,
    };

    try reads.settle(&fake);

    try std.testing.expectEqual(@as(u32, 1), calls);
    try std.testing.expect(!reads.waiting());
    try std.testing.expectEqual(@as(u32, 7), try typed.where(arena, "a"));
    try std.testing.expectError(error.NotFound, typed.where(arena, "b"));
    try std.testing.expectEqual(typed, try reads.typed_of("shop.item", &Probe.settle));
}
