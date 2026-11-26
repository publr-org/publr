//! A plugin's own collections: `publr.List(T)`, `publr.IdMap(V)` and `publr.IdList(V)`. Each
//! is made with `init(ctx)` and remembers the memory it was made in: it grows there whatever
//! is open when it grows, a walk's turn included, so a list made before a loop keeps what the
//! loop puts in it. None takes an allocator. Each tells how much it holds as it grows
//! (`held_note.zig`), so a plugin that runs out of memory is told which one filled it.
//!
//!     var totals = publr.IdMap(i64).init(ctx);
//!     var lines = Lines.where(ctx, .order, order.id);
//!
//!     while (try lines.next()) |line| {
//!         try totals.put(try lines.keep(line.value.item), line.value.amount);
//!     }
//!
//! Text put in one is not copied: a key or an item read from a walk's row is kept first.
const std = @import("std");
const id_map = @import("id_map.zig");
const queue = @import("../../sdk/plugin/queue.zig");
const Note = @import("../../sdk/plugin/held_note.zig").Note;

pub const Error = error{OutOfMemory};

/// What a collection of `Item` is called in the log: a record's rows by their kind
/// (`line records`), anything else by its type.
fn named(comptime Item: type) []const u8 {
    const container = @typeInfo(Item) == .@"struct";

    return if (container and @hasDecl(Item, "publr_name")) Item.publr_name else @typeName(Item);
}

/// The memory and the note a collection is made with: the call's memory where it is made.
const Made = struct {
    memory: std.mem.Allocator,
    note: Note,
};

fn made(any_ctx: anytype) Made {
    const ctx = queue.base_of(any_ctx);

    std.debug.assert(ctx.now().ms >= 0);

    return .{
        .memory = ctx.arena(),
        .note = Note.of(ctx),
    };
}

/// A list that grows in the memory it was made in: `var list = publr.List(T).init(ctx);`,
/// `try list.append(item)`, `list.items()`.
pub fn List(comptime Item: type) type {
    return struct {
        inner: std.ArrayList(Item) = .empty,
        memory: std.mem.Allocator,
        note: Note,

        const Self = @This();
        const name = "a publr.List of " ++ named(Item);

        pub fn init(any_ctx: anytype) Self {
            const at = made(any_ctx);

            return .{
                .memory = at.memory,
                .note = at.note,
            };
        }

        pub fn items(self: *const Self) []Item {
            return self.inner.items;
        }

        pub fn len(self: *const Self) u32 {
            std.debug.assert(self.inner.items.len <= self.inner.capacity);

            return @intCast(self.inner.items.len);
        }

        pub fn append(self: *Self, item: Item) Error!void {
            const before = self.inner.capacity;

            try self.inner.append(self.memory, item);
            self.noted(before);
        }

        pub fn append_slice(self: *Self, more: []const Item) Error!void {
            const before = self.inner.capacity;

            try self.inner.appendSlice(self.memory, more);
            self.noted(before);
        }

        /// Room for `count` items in all, exactly: what is appended up to it never moves the
        /// list.
        pub fn reserve(self: *Self, count: u64) Error!void {
            const before = self.inner.capacity;

            try self.inner.ensureTotalCapacityPrecise(self.memory, @intCast(count));
            self.noted(before);
        }

        fn noted(self: *const Self, before: u64) void {
            std.debug.assert(self.inner.capacity >= before);

            if (self.inner.capacity != before) {
                self.note.grew(name, @as(u64, self.inner.capacity) * @sizeOf(Item));
            }
        }
    };
}

/// A map keyed by text that is mostly ids, in the memory it was made in:
/// `var seen = publr.IdMap(u32).init(ctx);`, `try seen.put(id, 1)`, `seen.get(id)`.
pub fn IdMap(comptime Value: type) type {
    return struct {
        inner: Inner = .empty,
        memory: std.mem.Allocator,
        note: Note,

        const Self = @This();
        const Inner = id_map.Map(Value);
        const name = "a publr.IdMap of " ++ named(Value);
        const entry_bytes = @sizeOf([]const u8) + @sizeOf(Value) + 1;

        pub const Entry = Inner.Entry;
        pub const GetOrPut = Inner.GetOrPutResult;
        pub const Iterator = Inner.Iterator;

        pub fn init(any_ctx: anytype) Self {
            const at = made(any_ctx);

            return .{
                .memory = at.memory,
                .note = at.note,
            };
        }

        pub fn put(self: *Self, key: []const u8, value: Value) Error!void {
            const before = self.inner.capacity();

            try self.inner.put(self.memory, key, value);
            self.noted(before);
        }

        /// The key's place: `found_existing`, and pointers to the key and its value.
        pub fn get_or_put(self: *Self, key: []const u8) Error!GetOrPut {
            const before = self.inner.capacity();
            const place = try self.inner.getOrPut(self.memory, key);

            self.noted(before);

            std.debug.assert(place.key_ptr.len == key.len);

            return place;
        }

        pub fn get(self: *const Self, key: []const u8) ?Value {
            return self.inner.get(key);
        }

        pub fn get_ptr(self: *const Self, key: []const u8) ?*Value {
            return self.inner.getPtr(key);
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.inner.contains(key);
        }

        pub fn remove(self: *Self, key: []const u8) bool {
            return self.inner.remove(key);
        }

        pub fn count(self: *const Self) u32 {
            return self.inner.count();
        }

        pub fn iterator(self: *const Self) Iterator {
            return self.inner.iterator();
        }

        pub fn key_iterator(self: *const Self) Inner.KeyIterator {
            return self.inner.keyIterator();
        }

        /// Every key gone; the room stays for what is put next.
        pub fn clear(self: *Self) void {
            self.inner.clearRetainingCapacity();

            std.debug.assert(self.inner.count() == 0);
        }

        /// Room for `total` keys in all: putting up to it never grows the map.
        pub fn reserve(self: *Self, total: u64) Error!void {
            const before = self.inner.capacity();

            try self.inner.ensureTotalCapacity(self.memory, @intCast(total));
            self.noted(before);
        }

        fn noted(self: *const Self, before: u32) void {
            const capacity = self.inner.capacity();

            std.debug.assert(capacity >= before);

            if (capacity != before) {
                self.note.grew(name, @as(u64, capacity) * entry_bytes);
            }
        }
    };
}

/// `IdMap` that keeps its keys in the order they were put: `keys()` and `values()` are in
/// that order.
pub fn IdList(comptime Value: type) type {
    return struct {
        inner: Inner = .empty,
        memory: std.mem.Allocator,
        note: Note,

        const Self = @This();
        const Inner = id_map.OrderedMap(Value);
        const name = "a publr.IdList of " ++ named(Value);
        const entry_bytes = @sizeOf([]const u8) + @sizeOf(Value) + 8;

        pub const GetOrPut = Inner.GetOrPutResult;

        pub fn init(any_ctx: anytype) Self {
            const at = made(any_ctx);

            return .{
                .memory = at.memory,
                .note = at.note,
            };
        }

        pub fn put(self: *Self, key: []const u8, value: Value) Error!void {
            const before = self.inner.capacity();

            try self.inner.put(self.memory, key, value);
            self.noted(before);
        }

        /// The key's place: `found_existing`, and pointers to the key and its value.
        pub fn get_or_put(self: *Self, key: []const u8) Error!GetOrPut {
            const before = self.inner.capacity();
            const place = try self.inner.getOrPut(self.memory, key);

            self.noted(before);

            std.debug.assert(place.key_ptr.len == key.len);

            return place;
        }

        pub fn get(self: *const Self, key: []const u8) ?Value {
            return self.inner.get(key);
        }

        pub fn get_ptr(self: *const Self, key: []const u8) ?*Value {
            return self.inner.getPtr(key);
        }

        pub fn contains(self: *const Self, key: []const u8) bool {
            return self.inner.contains(key);
        }

        pub fn count(self: *const Self) u32 {
            return @intCast(self.inner.count());
        }

        /// The keys, in the order they were put.
        pub fn keys(self: *const Self) []const []const u8 {
            return self.inner.keys();
        }

        /// The values, in the order their keys were put.
        pub fn values(self: *const Self) []Value {
            return self.inner.values();
        }

        /// Room for `total` keys in all: putting up to it never grows the list.
        pub fn reserve(self: *Self, total: u64) Error!void {
            const before = self.inner.capacity();

            try self.inner.ensureTotalCapacity(self.memory, @intCast(total));
            self.noted(before);
        }

        fn noted(self: *const Self, before: u64) void {
            const capacity = self.inner.capacity();

            std.debug.assert(capacity >= before);

            if (capacity != before) {
                self.note.grew(name, @as(u64, capacity) * entry_bytes);
            }
        }
    };
}
