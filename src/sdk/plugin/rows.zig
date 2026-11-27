//! `publr.Rows`: many internal records read as a walk. The plugin asks for all of them and
//! loops; underneath, a page of them is read at a time, each from where the last ended,
//! and given back before the next is read. What the plugin allocates for one row (`ctx.arena()`
//! inside the loop, a record it reads for it) is the row's turn, given back at the next row.
//! At any moment the plugin holds one page, whatever the number of rows.
//!
//!     var lines = try Lines.where(ctx, .order, order.id);
//!
//!     while (try lines.next()) |line| {
//!         total += line.value.amount;
//!     }
//!
//! A row is good until the next `next`. A number, an enum or a flag copied out of it stays
//! good; text and lists are kept with `keep` into memory made before the loop. A walk left
//! early (`break`, `return`) holds its page until the work around it ends; `end` gives it
//! back at once.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../../sdk.zig");
const Error = @import("../../publr/operation.zig").Error;
const moved = @import("../moved.zig");
const internal_operations = @import("../../operations/internal.zig");
const internal_records = @import("../../store/internal_records.zig");
const record_define = @import("../../publr/plugin/record_define.zig");
const walks = @import("walks.zig");
const PluginCtx = @import("context.zig").PluginCtx;

/// What an indexed field is asked to hold: text as the index keeps it, or a whole number,
/// written out when the rows are read.
pub const Filter = union(enum) {
    text: []const u8,
    number: i64,
};

/// The longest whole number written out.
const number_bytes_max: u32 = 24;

/// The most rows a page reads: the page every list read is held to.
pub const page_rows: u32 = sdk.operation.page_limit_max;

/// In a debug build each row is handed out as a copy in its own turn, given back and
/// poisoned at the next, so a row kept past `next` reads rubbish in the first test that
/// keeps one.
const rows_poisoned = builtin.mode == .debug;

pub fn Rows(comptime Document: type, comptime kind: []const u8, comptime Wanted: type) type {
    comptime std.debug.assert(@typeInfo(Wanted) == .@"struct");

    const Kept = record_define.Store(Document, kind, true);

    return struct {
        ctx: *PluginCtx,
        /// The indexed field the rows hold `value` in; every record of the kind when null.
        field: ?[]const u8,
        value: ?Filter,
        oldest: bool = true,
        /// Rows still to hand out, when `first` bounds the walk.
        left: ?u32 = null,
        walk: ?walks.Handle = null,
        /// The memory the walk began in: where `kept` and `keep` copy.
        outer: ?std.mem.Allocator = null,
        page: []const Row = &.{},
        index: u32 = 0,
        /// The rows the last page asked for: a page with fewer was the last.
        asked: u32 = 0,
        after_bytes: [internal_records.id_bytes_max]u8 = undefined,
        after_len: u32 = 0,
        done: bool = false,
        /// Every page read into the memory the walk began in and kept there (`lasting`).
        lasting_rows: bool = false,
        held: Row = undefined,

        const Self = @This();

        /// One record: its id, version, when it was made and the fields `Wanted` names.
        pub const Row = Kept.FoundOf(Wanted);

        /// The next row, or null after the last. Good until the next call.
        pub fn next(self: *Self) Error!?*const Row {
            std.debug.assert(self.index <= self.page.len);

            if (self.done) {
                return null;
            }

            const handle = self.walk orelse try self.opened();

            // Given back with the work around it: a walk is read inside that work.
            if (!walks.alive(self.ctx, handle)) {
                return error.Invalid;
            }

            // A lasting walk keeps everything: its rows and what each turn made.
            if (!self.lasting_rows) {
                walks.turn_end(self.ctx, handle);
            }

            if (self.index == self.page.len and !try self.read_page(handle)) {
                self.end();

                return null;
            }

            const row = &self.page[self.index];

            self.index += 1;

            if (!self.lasting_rows) {
                walks.turn_begin(self.ctx, handle);
            }

            if (comptime rows_poisoned and moved.plain(Row)) {
                if (!self.lasting_rows) {
                    self.held = try moved.copy(Row, self.ctx.arena(), row.*);

                    return &self.held;
                }
            }

            return row;
        }

        /// `row` copied whole into the memory the walk began in, to outlive the loop: a
        /// deliberate act, for the rare walk that must hold its rows. A walk over many rows
        /// holding all of them holds all of their memory.
        pub fn kept(self: *const Self, row: *const Row) Error!Row {
            const outer = self.outer orelse return error.Invalid;

            comptime std.debug.assert(moved.plain(Row));

            return moved.copy(Row, outer, row.*) catch error.OutOfMemory;
        }

        /// `text` from a row copied into the memory the walk began in, to outlive the loop.
        pub fn keep(self: *const Self, text: []const u8) Error![]const u8 {
            const outer = self.outer orelse return error.Invalid;

            std.debug.assert(self.walk != null);

            return outer.dupe(u8, text) catch error.OutOfMemory;
        }

        /// The walk given back before its last row: what a loop left early may do.
        pub fn end(self: *Self) void {
            self.done = true;

            const handle = self.walk orelse return;

            walks.close(self.ctx, handle);
            self.page = &.{};

            std.debug.assert(!walks.alive(self.ctx, handle));
        }

        /// The same rows, newest first.
        pub fn newest(self: Self) Self {
            std.debug.assert(self.walk == null);

            var turned = self;

            turned.oldest = false;

            return turned;
        }

        /// At most `most` rows.
        /// The same rows, each read into the memory the walk began in and kept there, so every
        /// row outlives the loop: for the few reads that must hold all of them at once, which
        /// then hold all of their memory. Nothing is copied, and what the loop allocates stays
        /// too; a walk that looks at each row once leaves this out.
        pub fn lasting(self: Self) Self {
            std.debug.assert(self.walk == null);

            var kept_rows = self;

            kept_rows.lasting_rows = true;

            return kept_rows;
        }

        pub fn first(self: Self, most: u32) Self {
            std.debug.assert(self.walk == null);

            var bounded = self;

            bounded.left = most;

            return bounded;
        }

        /// The same rows, each with only the fields `Other` names, which alone are read.
        pub fn as(self: Self, comptime Other: type) Rows(Document, kind, Other) {
            std.debug.assert(self.walk == null);

            return .{
                .ctx = self.ctx,
                .field = self.field,
                .value = self.value,
                .oldest = self.oldest,
                .left = self.left,
                .lasting_rows = self.lasting_rows,
            };
        }

        /// A whole number of every row added up by the database, none handed over:
        /// `Lines.where(ctx, .cart, id).sum("priced.total")`. A computed field's values
        /// are worked out first where stale. `first` does not bound it.
        pub fn sum(self: Self, comptime path: []const u8) Error!i64 {
            comptime check_sum_path(Document, path);
            std.debug.assert(path.len > 0);

            // The rows a walk hands out are counted; a sum is of all of them.
            if (self.left != null) {
                return error.Invalid;
            }

            var number: [number_bytes_max]u8 = undefined;
            const added = try self.ctx.call(internal_operations.Sum, .{
                .kind = kind,
                .path = path,
                .field = self.field,
                .value = self.text_of(&number),
            });

            return added.sum;
        }

        /// How many rows: counted from the index, none read.
        pub fn count(self: Self) Error!u64 {
            var number: [number_bytes_max]u8 = undefined;
            const counted = try self.ctx.call(internal_operations.Count, .{
                .kind = kind,
                .field = self.field,
                .value = self.text_of(&number),
            });

            return if (self.left) |left| @min(counted.count, left) else counted.count;
        }

        /// Whether there is a row.
        pub fn any(self: Self) Error!bool {
            return try self.count() > 0;
        }

        /// The one row, or null when there is none; two are a conflict. Read in the
        /// caller's memory, never as a walk.
        pub fn one(self: Self) Error!?Row {
            std.debug.assert(self.walk == null);

            var number: [number_bytes_max]u8 = undefined;
            const asked = self.asking(2, "", &number);
            const found = try Kept.found_of(self.ctx, Wanted, &asked);

            if (found.len > 1) {
                return error.Conflict;
            }

            return if (found.len == 1) found[0] else null;
        }

        /// One page of rows and where the next begins.
        pub const Paged = struct {
            rows: []const Row,
            /// What `page_after` takes for the page after this one; empty after the last.
            next: []const u8,
        };

        /// The page of rows after `after` (empty for the first), read in the caller's memory:
        /// what an operation answering a page at a time hands back, with `next` for its
        /// caller to ask for the page after (`after` in its input, `next` in its answer).
        pub fn page_after(self: Self, after: []const u8) Error!Paged {
            std.debug.assert(self.walk == null);

            if (after.len > internal_records.id_bytes_max) {
                return error.Invalid;
            }

            const limit = @min(page_rows, self.left orelse page_rows);

            if (limit == 0) {
                return .{
                    .rows = &.{},
                    .next = "",
                };
            }

            var number: [number_bytes_max]u8 = undefined;
            const asked = self.asking(limit, after, &number);
            const found = try Kept.found_of(self.ctx, Wanted, &asked);
            const full = found.len == limit and self.left == null;

            std.debug.assert(found.len <= limit);

            return .{
                .rows = found,
                .next = if (full) found[found.len - 1].id else "",
            };
        }

        fn opened(self: *Self) Error!walks.Handle {
            std.debug.assert(self.walk == null);

            const handle = try walks.open(self.ctx);

            self.walk = handle;
            self.outer = self.ctx.arena();

            return handle;
        }

        /// The next page in its own memory, the last given back; false after the last.
        fn read_page(self: *Self, handle: walks.Handle) Error!bool {
            const started = self.asked > 0;

            std.debug.assert(self.index == self.page.len);

            if ((started and self.page.len < self.asked) or self.left == 0) {
                return false;
            }

            if (self.page.len > 0) {
                const last = self.page[self.page.len - 1].id;

                if (last.len > internal_records.id_bytes_max) {
                    return error.Invalid;
                }

                @memcpy(self.after_bytes[0..last.len], last);
                self.after_len = @intCast(last.len);
            }

            self.asked = @min(page_rows, self.left orelse page_rows);

            var number: [number_bytes_max]u8 = undefined;
            const asked = self.asking(self.asked, self.after_bytes[0..self.after_len], &number);

            if (self.lasting_rows) {
                // Between turns the call is back in the memory the walk began in.
                std.debug.assert(self.ctx.arena().ptr == self.outer.?.ptr);

                self.page = try Kept.found_of(self.ctx, Wanted, &asked);
            } else {
                walks.page_begin(self.ctx, handle);
                defer walks.page_leave(self.ctx, handle);

                self.page = &.{};
                self.page = try Kept.found_of(self.ctx, Wanted, &asked);
            }

            self.index = 0;

            if (self.left) |*left| {
                left.* -= @min(left.*, @as(u32, @intCast(self.page.len)));
            }

            return self.page.len > 0;
        }

        fn asking(
            self: *const Self,
            limit: u32,
            after: []const u8,
            number: *[number_bytes_max]u8,
        ) internal_operations.Find.In {
            std.debug.assert(limit > 0 and limit <= page_rows);
            std.debug.assert((self.field == null) == (self.value == null));

            return .{
                .kind = kind,
                .field = self.field,
                .value = self.text_of(number),
                .limit = limit,
                .oldest = self.oldest,
                .after = after,
                .fields = comptime record_define.projected(Document, Wanted),
            };
        }

        /// The value asked for as the index keeps it: text, or a number written out.
        fn text_of(self: *const Self, number: *[number_bytes_max]u8) ?[]const u8 {
            const value = self.value orelse return null;

            std.debug.assert(self.field != null);

            return switch (value) {
                .text => |text| text,
                .number => |whole| std.fmt.bufPrint(number, "{d}", .{whole}) catch unreachable,
            };
        }
    };
}

/// `path` names a whole number of `Document`, field by field: `priced.total`.
fn check_sum_path(comptime Document: type, comptime path: []const u8) void {
    comptime {
        var Current = Document;
        var parts = std.mem.splitScalar(u8, path, '.');

        std.debug.assert(path.len > 0);

        while (parts.next()) |part| {
            const Inner = if (@typeInfo(Current) == .optional)
                @typeInfo(Current).optional.child
            else
                Current;

            if (@typeInfo(Inner) != .@"struct" or !@hasField(Inner, part)) {
                @compileError("`sum(\"" ++ path ++ "\")`: " ++ @typeName(Inner) ++
                    " has no field `" ++ part ++ "`");
            }

            Current = @FieldType(Inner, part);
        }

        const Number = if (@typeInfo(Current) == .optional)
            @typeInfo(Current).optional.child
        else
            Current;

        if (@typeInfo(Number) != .int) {
            @compileError("`sum(\"" ++ path ++ "\")` adds up whole numbers; it names a " ++
                @typeName(Number));
        }
    }
}
