//! A saved view: the filters of the content list, named. The filters are data the admin
//! reads and writes as JSON: the types the list spans, one clause per filter (its key,
//! an operator, a value), a search and an order. `me` and durations are resolved when the
//! list is asked, so a saved view stays current.

const std = @import("std");
const filter = @import("filter.zig");

pub const name_len_max: u32 = 80;
pub const query_bytes_max: u32 = 4 << 10;
pub const types_max: u32 = 64;
pub const clauses_max: u32 = filter.filters_max;
pub const value_len_max: u32 = filter.value_len_max;
pub const me = filter.me.id;

pub const Error = error{ Invalid, OutOfMemory };

pub const orders = [_][]const u8{ "updated_desc", "created_desc", "title_asc" };

pub const Clause = filter.Clause;

/// What the content list is asked for. Every field is optional: the empty value is the
/// whole content. `types` narrows the content to some types; `type_view` says the list is
/// one type's own view (one type, no type pill) rather than the content narrowed to it.
pub const Filters = struct {
    types: []const []const u8 = &.{},
    type_view: bool = false,
    clauses: []const Clause = &.{},
    search: ?[]const u8 = null,
    order: ?[]const u8 = null,

    pub fn is_empty(filters: Filters) bool {
        std.debug.assert(filters.types.len <= types_max);

        return filters.types.len == 0 and !filters.type_view and filters.clauses.len == 0 and
            filters.search == null and filters.order == null;
    }

    pub fn clause(filters: Filters, key: []const u8) ?Clause {
        std.debug.assert(key.len > 0);
        std.debug.assert(filters.clauses.len <= clauses_max);

        for (filters.clauses) |candidate| {
            if (std.mem.eql(u8, candidate.key, key)) {
                return candidate;
            }
        }

        return null;
    }
};

pub fn decode(arena: std.mem.Allocator, text: []const u8) Error!Filters {
    std.debug.assert(query_bytes_max > 0);

    if (text.len > query_bytes_max) {
        return error.Invalid;
    }

    const filters = @import("../lib/json.zig").parse(Filters, arena, text, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };

    try validate(filters);

    return filters;
}

pub fn encode(arena: std.mem.Allocator, filters: Filters) Error![]const u8 {
    std.debug.assert(filters.types.len <= types_max);

    try validate(filters);

    return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(filters, .{
        .emit_null_optional_fields = false,
    })}) catch return error.OutOfMemory;
}

/// Bounds and shapes only: whether a type, a filter or a user exists is the list's question.
pub fn validate(filters: Filters) Error!void {
    std.debug.assert(types_max > 0);

    if (filters.types.len > types_max or filters.clauses.len > clauses_max) {
        return error.Invalid;
    }

    if (filters.type_view and filters.types.len != 1) {
        return error.Invalid;
    }

    for (filters.types) |handle| {
        try check_text(handle, filter.key_len_max);
    }

    for (filters.clauses, 0..) |clause, index| {
        try check_text(clause.key, filter.key_len_max);
        try check_text(clause.operator, filter.operator_len_max);

        if (clause.value.len > value_len_max) {
            return error.Invalid;
        }

        for (filters.clauses[index + 1 ..]) |other| {
            const same_operator = std.mem.eql(u8, clause.operator, other.operator);

            if (std.mem.eql(u8, clause.key, other.key) and same_operator) {
                return error.Invalid;
            }
        }
    }

    if (filters.search) |search| {
        try check_text(search, value_len_max);
    }

    if (filters.order) |order| {
        if (!is_order(order)) {
            return error.Invalid;
        }
    }
}

/// The filters with `clause` in place of the clause at `index`, or added at the end when
/// `index` is past them. Which clause a new one replaces is the registry's question (the
/// one settling the same thing), asked by the caller.
pub fn with(
    arena: std.mem.Allocator,
    filters: Filters,
    index: u32,
    clause: Clause,
) error{OutOfMemory}!Filters {
    std.debug.assert(clause.key.len > 0);
    std.debug.assert(filters.clauses.len <= clauses_max);

    var clauses: std.ArrayList(Clause) = .empty;

    for (filters.clauses, 0..) |existing, position| {
        clauses.append(arena, if (position == index) clause else existing) catch {
            return error.OutOfMemory;
        };
    }

    if (index >= filters.clauses.len) {
        clauses.append(arena, clause) catch return error.OutOfMemory;
    }

    var out = filters;
    out.clauses = clauses.items;

    return out;
}

/// The filters without the clause at `index`.
pub fn without(
    arena: std.mem.Allocator,
    filters: Filters,
    index: u32,
) error{OutOfMemory}!Filters {
    std.debug.assert(index < filters.clauses.len);
    std.debug.assert(filters.clauses.len <= clauses_max);

    var clauses: std.ArrayList(Clause) = .empty;

    for (filters.clauses, 0..) |existing, position| {
        if (position != index) {
            clauses.append(arena, existing) catch return error.OutOfMemory;
        }
    }

    var out = filters;
    out.clauses = clauses.items;

    return out;
}

fn check_text(text: []const u8, len_max: u32) Error!void {
    std.debug.assert(len_max > 0);

    if (text.len == 0 or text.len > len_max) {
        return error.Invalid;
    }

    std.debug.assert(text.len <= len_max);
}

pub fn is_order(text: []const u8) bool {
    std.debug.assert(orders.len == 3);

    for (orders) |candidate| {
        if (std.mem.eql(u8, candidate, text)) {
            return true;
        }
    }

    return false;
}

test "encode and decode round-trip, empty filters encode small, bad shapes are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const filters: Filters = .{
        .types = &.{ "post", "page" },
        .clauses = &.{
            .{ .key = "status", .operator = "is", .value = "draft" },
            .{ .key = "updated", .operator = "within", .value = "7d" },
        },
        .order = "title_asc",
    };
    const text = try encode(arena, filters);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"operator\":\"within\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "search") == null);
    const back = try decode(arena, text);
    try std.testing.expectEqual(@as(usize, 2), back.types.len);
    try std.testing.expectEqualStrings("draft", back.clause("status").?.value);
    try std.testing.expect(back.clause("nope") == null);
    try std.testing.expect(!back.is_empty());

    try std.testing.expect((try decode(arena, "{}")).is_empty());
    try std.testing.expectEqualStrings(
        "{\"types\":[],\"type_view\":false,\"clauses\":[]}",
        try encode(arena, .{}),
    );
    try std.testing.expectError(error.Invalid, decode(arena, "{\"order\":\"sideways\"}"));
    try std.testing.expectError(error.Invalid, decode(arena, "{\"type_view\":true}"));
    const twice = "{\"clauses\":[{\"key\":\"status\",\"operator\":\"is\"}," ++
        "{\"key\":\"status\",\"operator\":\"is\",\"value\":\"x\"}]}";
    try std.testing.expectError(error.Invalid, decode(arena, twice));
    const two_ways = "{\"clauses\":[{\"key\":\"created\",\"operator\":\"by\"}," ++
        "{\"key\":\"created\",\"operator\":\"within\"}]}";
    try std.testing.expectEqual(@as(usize, 2), (try decode(arena, two_ways)).clauses.len);
    try std.testing.expectError(error.Invalid, decode(arena, "{\"clauses\":[{\"key\":\"\"}]}"));
    try std.testing.expectError(error.Invalid, decode(arena, "{\"nope\":1}"));
    try std.testing.expectError(error.Invalid, decode(arena, "not json"));

    const added = try with(arena, .{}, 0, .{ .key = "status", .operator = "is", .value = "draft" });
    try std.testing.expectEqual(@as(usize, 1), added.clauses.len);
    const not_x: Clause = .{ .key = "status", .operator = "not", .value = "x" };
    const swapped = try with(arena, added, 0, not_x);
    try std.testing.expectEqual(@as(usize, 1), swapped.clauses.len);
    try std.testing.expectEqualStrings("not", swapped.clause("status").?.operator);
    const by_me: Clause = .{ .key = "created", .operator = "by", .value = "me" };
    const more = try with(arena, swapped, 9, by_me);
    try std.testing.expectEqual(@as(usize, 2), more.clauses.len);
    try std.testing.expectEqualStrings("created", more.clauses[1].key);
    try std.testing.expectEqual(@as(usize, 1), (try without(arena, more, 0)).clauses.len);
    try std.testing.expect((try without(arena, swapped, 0)).is_empty());
}
