//! What a filter reads while it runs over a batch. The first pass only notes each read and
//! answers `error.NotYet`; `settle` then reads every noted record in one `record.list` and
//! anything else once per distinct input, and the next pass is answered from them.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const record = @import("../../operations/record.zig");

const Error = sdk.Error;

/// A read that depends on a read takes another round; past this the item stays as it was.
pub const rounds_max: u32 = 4;
pub const entries_max: u32 = 512;

pub const Entry = struct {
    name: []const u8,
    input: []const u8,
    answer: ?[]const u8 = null,
    failed: ?Error = null,

    fn settled(entry: *const Entry) bool {
        return entry.answer != null or entry.failed != null;
    }
};

pub const Reads = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    /// The answer kept for this call, or a note of it and `error.NotYet`.
    pub fn answer(
        self: *Reads,
        comptime Out: type,
        name: []const u8,
        in: anytype,
    ) Error!Out {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.entries.items.len <= entries_max);

        const input = std.json.Stringify.valueAlloc(self.arena, in, .{}) catch {
            return error.OutOfMemory;
        };

        for (self.entries.items) |entry| {
            if (!std.mem.eql(u8, entry.name, name) or !std.mem.eql(u8, entry.input, input)) {
                continue;
            }

            if (entry.failed) |err| {
                return err;
            }

            const text = entry.answer orelse return error.NotYet;

            return std.json.parseFromSliceLeaky(Out, self.arena, text, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch error.Invalid;
        }

        if (self.entries.items.len == entries_max) {
            return error.Invalid;
        }

        self.entries.append(self.arena, .{
            .name = name,
            .input = input,
        }) catch return error.OutOfMemory;

        return error.NotYet;
    }

    /// Whether a read is noted and not answered yet.
    pub fn waiting(self: *const Reads) bool {
        std.debug.assert(self.entries.items.len <= entries_max);

        for (self.entries.items) |*entry| {
            if (!entry.settled()) {
                return true;
            }
        }

        return false;
    }

    /// Answers every noted read through `api.call_json`: the plain `record.get`s together in
    /// one `record.list`, anything else once each, and so is a get the list did not reach (a
    /// plugin's list reaches only the types its grant names).
    pub fn settle(self: *Reads, api: anytype) Error!void {
        std.debug.assert(self.entries.items.len <= entries_max);

        try self.settle_gets(api);

        for (self.entries.items) |*entry| {
            if (entry.settled()) {
                continue;
            }

            entry.answer = api.call_json(entry.name, entry.input) catch |err| {
                entry.failed = err;
                continue;
            };
        }

        std.debug.assert(!self.waiting());
    }

    fn settle_gets(self: *Reads, api: anytype) Error!void {
        var ids: std.ArrayList([]const u8) = .empty;
        var gets: std.ArrayList(*Entry) = .empty;

        for (self.entries.items) |*entry| {
            const id = plain_get(self.arena, entry) orelse continue;

            ids.append(self.arena, id) catch return error.OutOfMemory;
            gets.append(self.arena, entry) catch return error.OutOfMemory;
        }

        if (ids.items.len == 0) {
            return;
        }

        std.debug.assert(ids.items.len <= record.list_max);

        const input = std.json.Stringify.valueAlloc(self.arena, record.List.In{
            .ids = ids.items,
            .limit = @intCast(ids.items.len),
            .documents = true,
            .expand = false,
            .purpose = .edit,
        }, .{}) catch return error.OutOfMemory;
        // A list that fails leaves each get to be read on its own.
        const text = api.call_json(record.List.name, input) catch return;
        const listed = std.json.parseFromSliceLeaky(record.List.Out, self.arena, text, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.Invalid;

        for (gets.items, ids.items) |entry, id| {
            try self.answer_get(entry, id, listed);
        }
    }

    fn answer_get(self: *Reads, entry: *Entry, id: []const u8, listed: record.List.Out) Error!void {
        std.debug.assert(id.len > 0);
        std.debug.assert(listed.documents.len == listed.records.len);

        for (listed.records, listed.documents) |row, document| {
            if (!std.mem.eql(u8, row.id, id)) {
                continue;
            }

            const got: record.Get.Out = .{
                .record = row,
                .slot = "live",
                .document = document,
            };

            entry.answer = std.json.Stringify.valueAlloc(self.arena, got, .{}) catch {
                return error.OutOfMemory;
            };

            return;
        }
    }
};

/// The id of a noted `record.get` that asks for the record as stored, as a typed handle reads
/// it and a list of ids can too.
fn plain_get(arena: std.mem.Allocator, entry: *const Entry) ?[]const u8 {
    std.debug.assert(entry.name.len > 0);

    if (entry.settled() or !std.mem.eql(u8, entry.name, record.Get.name)) {
        return null;
    }

    const in = std.json.parseFromSliceLeaky(record.Get.In, arena, entry.input, .{
        .allocate = .alloc_always,
    }) catch return null;
    const plain = in.purpose == .edit and in.slot == null and in.variant == null;

    return if (plain and in.id.len > 0) in.id else null;
}

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
