//! The content list's filters in their three shapes: the address the browser holds
//! (`?types=post&status=is:draft&updated=within:7d`; `?type=post` is the type's own view),
//! the saved view's `model.view.Filters`, and the list operation's input. Which filters
//! exist, their operators and what they take come from the registry; this only carries
//! them.
const std = @import("std");
const model = @import("../../../model.zig");
const registry = @import("../../../server/registry.zig");
const record_operations = @import("../../../operations/record.zig");

const Filters = model.view.Filters;
const Clause = model.filter.Clause;
const ListIn = record_operations.List.In;
const Order = record_operations.Order;

pub const Error = error{OutOfMemory};

pub const query_len_max: u32 = 64 << 10;
/// Rows on one page of the list; the page is rendered whole, so it stays small.
pub const page_size: u32 = 20;
/// A filter's operator may also come as its own parameter (`updated_operator=after`), the
/// way a form with a date input sends it; `key=operator:value` is the usual shape.
pub const operator_suffix = "_operator";

/// The filters an address carries. A clause the registry does not know, or a value its
/// operator cannot take, is left out rather than refused: the address is the user's.
pub fn parse(arena: std.mem.Allocator, query: []const u8) Error!Filters {
    std.debug.assert(query.len <= query_len_max);
    std.debug.assert(registry.Filters.all.len > 0);

    var filters: Filters = .{};
    var types: std.ArrayList([]const u8) = .empty;
    var clauses: std.ArrayList(Clause) = .empty;
    var own_view = false;
    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = pair[0..equals];
        const encoded = if (equals < pair.len) pair[equals + 1 ..] else "";
        const raw = decode(arena, encoded) orelse continue;
        const value = std.mem.trim(u8, raw, " ");

        if (value.len > model.view.value_len_max) {
            continue;
        }

        if (std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "types")) {
            own_view = own_view or std.mem.eql(u8, key, "type");

            const room = types.items.len < model.view.types_max;

            if (value.len > 0 and room and !contains(types.items, value)) {
                types.append(arena, value) catch return error.OutOfMemory;
            }
        } else if (std.mem.eql(u8, key, "q")) {
            filters.search = if (value.len > 0) value else null;
        } else if (std.mem.eql(u8, key, "order")) {
            filters.order = if (model.view.is_order(value)) value else null;
        } else if (std.mem.eql(u8, key, "per_page")) {
            const number = std.fmt.parseInt(u32, value, 10) catch 0;
            const known = std.mem.indexOfScalar(u32, &model.view.per_page_choices, number);

            filters.per_page = if (known != null) number else null;
        } else if (std.mem.eql(u8, key, "columns")) {
            filters.columns = try names_of(arena, value);
        } else if (model.field_filter.field_of(key) != null) {
            if (part_of(key) == null) {
                const operator_text = operator_param(arena, query, key);

                try place(arena, &clauses, field_clause(key, value, operator_text));
            } else {
                try place_parts(arena, &clauses, query, key);
            }
        } else if (registry.Filters.find(key)) |def| {
            const operator_text = operator_param(arena, query, key);

            try place(arena, &clauses, clause_of(def, value, operator_text));
        }
    }

    filters.types = types.items;
    filters.type_view = own_view and types.items.len == 1;
    filters.clauses = clauses.items;

    return filters;
}

/// `number,total`: names, the empty ones dropped; past the most a view holds, the rest too.
fn names_of(arena: std.mem.Allocator, value: []const u8) Error![]const []const u8 {
    std.debug.assert(value.len <= model.view.value_len_max);

    var names: std.ArrayList([]const u8) = .empty;
    var parts = std.mem.splitScalar(u8, value, ',');

    while (parts.next()) |part| {
        const name = std.mem.trim(u8, part, " ");
        const fits = name.len > 0 and name.len <= model.filter.key_len_max;

        if (fits and names.items.len < model.view.columns_max) {
            names.append(arena, name) catch return error.OutOfMemory;
        }
    }

    return names.items;
}

/// A clause on a field: `field.total=more:4999`, the operator before the first colon; or a
/// bare value under the operator its own parameter names (`field.total_operator=more`), as
/// a pill's form sends it. Which operators a field takes is its type's; the list page drops
/// the ones it does not.
fn field_clause(key: []const u8, text: []const u8, operator_text: ?[]const u8) Clause {
    std.debug.assert(key.len > model.field_filter.prefix.len);

    if (operator_text) |named| {
        const valid = named.len > 0 and named.len <= model.filter.operator_len_max;

        return .{
            .key = key,
            .operator = if (valid) named else "is",
            .value = if (valid) text else "",
        };
    }

    const colon = std.mem.indexOfScalar(u8, text, ':') orelse text.len;
    const operator = text[0..colon];
    const valid = operator.len > 0 and operator.len <= model.filter.operator_len_max;

    return .{
        .key = key,
        .operator = if (valid) operator else "is",
        .value = if (valid and colon < text.len) text[colon + 1 ..] else "",
    };
}

/// The parts a pill's form sends a field's value in: a range's two ends, a span's count and
/// its unit, the operator.
const part_suffixes = [_][]const u8{ "_from", "_to", "_count", "_unit", operator_suffix };

/// The field key a part's parameter belongs to: `field.total_from` is `field.total`'s.
fn part_of(key: []const u8) ?[]const u8 {
    for (part_suffixes) |suffix| {
        if (std.mem.endsWith(u8, key, suffix) and key.len > suffix.len) {
            const field = key[0 .. key.len - suffix.len];
            std.debug.assert(field.len > 0);

            return field;
        }
    }

    return null;
}

/// A range (`_from`, `_to`) or a span (`_count`, `_unit`) put back into one clause:
/// `10..20`, `7d`; placed once, when its first part comes.
fn place_parts(
    arena: std.mem.Allocator,
    clauses: *std.ArrayList(Clause),
    query: []const u8,
    part_key: []const u8,
) Error!void {
    std.debug.assert(query.len <= query_len_max);

    const key = part_of(part_key) orelse return;
    const first = std.mem.endsWith(u8, part_key, "_from") or
        std.mem.endsWith(u8, part_key, "_count");

    if (!first or model.field_filter.field_of(key) == null) {
        return;
    }

    const low = param(arena, query, key, "_from");
    const high = param(arena, query, key, "_to");
    const count = param(arena, query, key, "_count");
    const unit = param(arena, query, key, "_unit");
    const operator = param(arena, query, key, operator_suffix) orelse return;
    const value = if (low != null and high != null)
        std.fmt.allocPrint(arena, "{s}..{s}", .{ low.?, high.? }) catch return error.OutOfMemory
    else if (count != null and unit != null)
        std.fmt.allocPrint(arena, "{s}{s}", .{ count.?, unit.? }) catch return error.OutOfMemory
    else
        "";

    try place(arena, clauses, field_clause(key, value, operator));
}

fn param(
    arena: std.mem.Allocator,
    query: []const u8,
    key: []const u8,
    suffix: []const u8,
) ?[]const u8 {
    std.debug.assert(key.len > 0);

    const name = std.fmt.allocPrint(arena, "{s}{s}", .{ key, suffix }) catch return null;
    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        if (std.mem.eql(u8, pair[0..equals], name)) {
            const value = decode(arena, pair[equals + 1 ..]) orelse return null;
            const trimmed = std.mem.trim(u8, value, " ");

            const fits = trimmed.len > 0 and trimmed.len <= model.view.value_len_max;

            return if (fits) trimmed else null;
        }
    }

    return null;
}

/// One filter's parameter as a clause: `operator:value`, or a bare value under the
/// operator its own parameter names, else under the first operator. A value the operator
/// cannot take, or under an operator the filter has not, is dropped, the pill kept.
fn clause_of(def: model.filter.Definition, text: []const u8, operator_text: ?[]const u8) Clause {
    std.debug.assert(def.operators.len > 0);
    std.debug.assert(text.len <= model.view.value_len_max);

    var operator = def.operators[0];
    var value = text;

    if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
        if (def.operator(text[0..colon])) |named| {
            operator = named;
            value = text[colon + 1 ..];
        } else {
            value = "";
        }
    } else if (operator_text) |name| {
        if (def.operator(name)) |named| {
            operator = named;
        }
    }

    return .{
        .key = def.key,
        .operator = operator.id,
        .value = if (model.filter.fits(operator, value)) value else "",
    };
}

fn operator_param(arena: std.mem.Allocator, query: []const u8, key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(query.len <= query_len_max);

    const name = std.fmt.allocPrint(arena, "{s}{s}", .{ key, operator_suffix }) catch return null;
    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        if (std.mem.eql(u8, pair[0..equals], name)) {
            return decode(arena, pair[equals + 1 ..]);
        }
    }

    return null;
}

/// A clause that clashes with one already placed (same filter, operators settling the same
/// thing) replaces it; one settling something else stands beside it.
fn place(arena: std.mem.Allocator, clauses: *std.ArrayList(Clause), clause: Clause) Error!void {
    std.debug.assert(clause.key.len > 0);
    std.debug.assert(clauses.items.len <= model.view.clauses_max);

    const on_field = model.field_filter.field_of(clause.key) != null;

    for (clauses.items) |*existing| {
        const same_field = on_field and std.mem.eql(u8, existing.key, clause.key);

        if (same_field or (!on_field and registry.Filters.clash(existing.*, clause))) {
            existing.* = clause;

            return;
        }
    }

    if (clauses.items.len < model.view.clauses_max) {
        clauses.append(arena, clause) catch return error.OutOfMemory;
    }
}

/// Whether the address names a list and nothing about it (`?type=order`, a page number
/// aside): the list starts where its default view does.
pub fn bare(query: []const u8) bool {
    std.debug.assert(query.len <= query_len_max);

    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = pair[0..equals];
        const quiet = key.len == 0 or std.mem.eql(u8, key, "type") or
            std.mem.eql(u8, key, "types") or std.mem.eql(u8, key, "page") or
            std.mem.eql(u8, key, "view");

        if (!quiet) {
            return false;
        }
    }

    return true;
}

/// The parts of a view an address left out, from the view it rests on: the columns, the
/// page size and the order. Clauses and the search stay as given: an
/// address without them asks for none.
pub fn completed(given: Filters, resting: Filters) Filters {
    std.debug.assert(given.clauses.len <= model.view.clauses_max);
    std.debug.assert(resting.clauses.len <= model.view.clauses_max);

    var out = given;

    out.order = given.order orelse resting.order;
    out.columns = given.columns orelse resting.columns;
    out.per_page = given.per_page orelse resting.per_page;

    return out;
}

/// Whether the address carries any filter at all, besides a view.
pub fn any_present(query: []const u8) bool {
    std.debug.assert(query.len <= query_len_max);
    std.debug.assert(registry.Filters.all.len > 0);

    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = pair[0..equals];
        const known = std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "types") or
            std.mem.eql(u8, key, "q") or std.mem.eql(u8, key, "order") or
            std.mem.eql(u8, key, "per_page") or std.mem.eql(u8, key, "columns") or
            model.field_filter.field_of(key) != null;

        if (known or registry.Filters.find(key) != null) {
            return true;
        }
    }

    return false;
}

/// The address of the list, `/admin/content?...`: the view when there is one, then the
/// types, then the clauses in the order they were added, then the search and the order.
pub fn format(arena: std.mem.Allocator, filters: Filters, view_id: ?[]const u8) Error![]const u8 {
    std.debug.assert(filters.types.len <= model.view.types_max);
    std.debug.assert(filters.clauses.len <= model.view.clauses_max);

    var out: std.Io.Writer.Allocating = .init(arena);
    const writer = &out.writer;
    var separator: u8 = '?';

    writer.writeAll("/admin/content") catch return error.OutOfMemory;

    if (view_id) |id| {
        try write_pair(writer, &separator, "view", id);
    }

    const type_key: []const u8 = if (filters.type_view and filters.types.len == 1)
        "type"
    else
        "types";

    for (filters.types) |handle| {
        try write_pair(writer, &separator, type_key, handle);
    }

    for (filters.clauses) |clause| {
        const parts = .{ clause.operator, clause.value };
        const text = std.fmt.allocPrint(arena, "{s}:{s}", parts) catch return error.OutOfMemory;

        try write_pair(writer, &separator, clause.key, text);
    }

    if (filters.search) |search| {
        try write_pair(writer, &separator, "q", search);
    }

    if (filters.order) |order| {
        try write_pair(writer, &separator, "order", order);
    }

    if (filters.per_page) |per_page| {
        const text = std.fmt.allocPrint(arena, "{d}", .{per_page}) catch return error.OutOfMemory;

        try write_pair(writer, &separator, "per_page", text);
    }

    if (filters.columns) |names| {
        const text = std.mem.join(arena, ",", names) catch return error.OutOfMemory;

        try write_pair(writer, &separator, "columns", text);
    }

    return out.written();
}

/// Whether two filter sets ask for the same list, whatever order their clauses came in.
pub fn same(arena: std.mem.Allocator, left: Filters, right: Filters) Error!bool {
    std.debug.assert(left.types.len <= model.view.types_max);
    std.debug.assert(right.types.len <= model.view.types_max);

    const left_text = try format(arena, try sorted(arena, left), null);
    const right_text = try format(arena, try sorted(arena, right), null);

    return std.mem.eql(u8, left_text, right_text);
}

/// The filters with their clauses in key, then operator, order.
fn sorted(arena: std.mem.Allocator, filters: Filters) Error!Filters {
    std.debug.assert(filters.clauses.len <= model.view.clauses_max);
    std.debug.assert(filters.types.len <= model.view.types_max);

    const clauses = arena.dupe(Clause, filters.clauses) catch return error.OutOfMemory;

    std.mem.sort(Clause, clauses, {}, struct {
        fn before(_: void, left: Clause, right: Clause) bool {
            std.debug.assert(left.key.len > 0);
            std.debug.assert(right.key.len > 0);

            if (std.mem.eql(u8, left.key, right.key)) {
                return std.mem.lessThan(u8, left.operator, right.operator);
            }

            return std.mem.lessThan(u8, left.key, right.key);
        }
    }.before);

    var out = filters;
    out.clauses = clauses;

    return out;
}

/// The list operation's input: one type goes as `type`, several as `types`, each clause
/// as `key:operator:value`; what a clause means is the registry's business there.
pub fn list_in(arena: std.mem.Allocator, filters: Filters) Error!ListIn {
    std.debug.assert(filters.types.len <= model.view.types_max);
    std.debug.assert(page_size > 0 and page_size <= record_operations.list_max);

    var clauses: std.ArrayList([]const u8) = .empty;

    for (filters.clauses) |clause| {
        // A pill on a field with nothing chosen yet asks nothing of the list.
        if (model.field_filter.field_of(clause.key) != null and clause.value.len == 0) {
            continue;
        }

        clauses.append(arena, std.fmt.allocPrint(arena, "{s}:{s}:{s}", .{
            clause.key,
            clause.operator,
            clause.value,
        }) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }

    return .{
        .type = if (filters.types.len == 1) filters.types[0] else null,
        .types = if (filters.types.len > 1) filters.types else &.{},
        .filters = clauses.items,
        .search = filters.search,
        .order = order_of(filters.order),
        .sort = sort_of(filters.order),
        .limit = filters.per_page orelse page_size,
    };
}

/// The list's order by one of core's columns: `title`, `-updated`; newest saved first when
/// the view orders by a field (`sort_of`) or says nothing.
pub fn order_of(text: ?[]const u8) Order {
    std.debug.assert(model.view.core_orders.len == 4);

    const name = (text orelse return .updated_desc);
    const descending = std.mem.startsWith(u8, name, "-");
    const column = if (descending) name[1..] else name;
    const by = std.meta.stringToEnum(enum { title, created, updated, status }, column) orelse {
        return .updated_desc;
    };

    return switch (by) {
        .title => if (descending) .title_desc else .title_asc,
        .created => if (descending) .created_desc else .created_asc,
        .updated => if (descending) .updated_desc else .updated_asc,
        .status => if (descending) .status_desc else .status_asc,
    };
}

/// The field the view orders by, `total` or `-total`; null for one of core's orders.
pub fn sort_of(text: ?[]const u8) ?[]const u8 {
    const name = text orelse return null;

    std.debug.assert(name.len > 0);

    return if (model.view.is_core_order(name)) null else (name);
}

fn write_pair(
    writer: *std.Io.Writer,
    separator: *u8,
    key: []const u8,
    value: []const u8,
) Error!void {
    std.debug.assert(key.len > 0);
    std.debug.assert(separator.* == '?' or separator.* == '&');

    writer.print("{c}{s}=", .{ separator.*, key }) catch return error.OutOfMemory;
    separator.* = '&';
    encode(writer, value) catch return error.OutOfMemory;
}

/// Form-style percent encoding: unreserved bytes, `:` and `,` as they are, a space as `+`.
pub fn encode(writer: *std.Io.Writer, text: []const u8) !void {
    std.debug.assert(text.len <= query_len_max);
    std.debug.assert(query_len_max > 0);

    for (text) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or
            byte == '.' or byte == '~' or byte == ':' or byte == ',';

        if (plain) {
            try writer.writeByte(byte);
        } else if (byte == ' ') {
            try writer.writeByte('+');
        } else {
            try writer.print("%{X:0>2}", .{byte});
        }
    }
}

/// Percent-decoding of one value: `+` a space, `%XX` a byte; null when malformed.
pub fn decode(arena: std.mem.Allocator, encoded: []const u8) ?[]const u8 {
    std.debug.assert(encoded.len <= query_len_max);

    var out = arena.alloc(u8, encoded.len) catch return null;
    var len: u32 = 0;
    var index: u32 = 0;

    while (index < encoded.len) : (index += 1) {
        const char = encoded[index];

        if (char == '+') {
            out[len] = ' ';
        } else if (char == '%') {
            if (index + 2 >= encoded.len) {
                return null;
            }

            out[len] = std.fmt.parseInt(u8, encoded[index + 1 .. index + 3], 16) catch return null;
            index += 2;
        } else {
            out[len] = char;
        }

        len += 1;
    }

    return out[0..len];
}

fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(list.len <= model.view.types_max);
    std.debug.assert(item.len > 0);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

test "an address parses to filters and formats back in one order; junk is dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const query = "order=title&types=page&status=not:draft&types=post&types=page" ++
        "&q=hello+world&updated=within:7d&created=before:soon&changed=" ++
        "&view=abc&nope=1";
    const filters = try parse(arena, query);
    try std.testing.expectEqual(@as(usize, 2), filters.types.len);
    try std.testing.expectEqualStrings("page", filters.types[0]);
    try std.testing.expect(!filters.type_view);
    try std.testing.expectEqualStrings("not", filters.clause("status").?.operator);
    try std.testing.expectEqualStrings("draft", filters.clause("status").?.value);
    try std.testing.expectEqualStrings("hello world", filters.search.?);
    try std.testing.expectEqualStrings("7d", filters.clause("updated").?.value);
    try std.testing.expectEqualStrings("", filters.clause("created").?.value);
    try std.testing.expectEqualStrings("before", filters.clause("created").?.operator);
    try std.testing.expectEqualStrings("", filters.clause("changed").?.value);
    try std.testing.expectEqualStrings("title", filters.order.?);

    const address = try format(arena, filters, "abc");
    try std.testing.expectEqualStrings(
        "/admin/content?view=abc&types=page&types=post&status=not:draft" ++
            "&updated=within:7d&created=before:&changed=is:&q=hello+world&order=title",
        address,
    );
    try std.testing.expect(try same(arena, filters, try parse(arena, address[15..])));
    try std.testing.expect(!try same(arena, filters, .{}));
    const reordered = try parse(arena, "changed=is:&created=before:&updated=within:7d");
    const in_order = try parse(arena, "updated=within:7d&created=before:&changed=is:");
    try std.testing.expect(try same(arena, reordered, in_order));
    try std.testing.expect(!std.mem.eql(
        u8,
        try format(arena, reordered, null),
        try format(arena, in_order, null),
    ));
    const by_me = try parse(arena, "created=by:me&updated=nope:x");
    try std.testing.expectEqualStrings("by", by_me.clause("created").?.operator);
    try std.testing.expectEqualStrings("me", by_me.clause("created").?.value);
    try std.testing.expectEqualStrings("", by_me.clause("updated").?.value);
    const two_ways = try parse(arena, "created=by:me&created=within:7d&created=after:2026-01-01");
    try std.testing.expectEqual(@as(usize, 2), two_ways.clauses.len);
    try std.testing.expectEqualStrings("after", two_ways.clauses[1].operator);
    try std.testing.expectEqualStrings(
        "/admin/content?created=by:me&created=after:2026-01-01",
        try format(arena, two_ways, null),
    );
    try std.testing.expectEqualStrings("/admin/content", try format(arena, .{}, null));

    const from_form = try parse(arena, "updated_operator=after&updated=2026-01-02");
    try std.testing.expectEqualStrings("after", from_form.clause("updated").?.operator);
    try std.testing.expectEqualStrings("2026-01-02", from_form.clause("updated").?.value);
    try std.testing.expect(any_present("view=abc&q="));
    try std.testing.expect(any_present("status"));
    try std.testing.expect(!any_present("view=abc&nope=1"));

    const in = try list_in(arena, filters);
    try std.testing.expect(in.type == null);
    try std.testing.expectEqual(@as(usize, 2), in.types.len);
    try std.testing.expectEqual(@as(usize, 4), in.filters.len);
    try std.testing.expectEqualStrings("status:not:draft", in.filters[0]);
    try std.testing.expectEqualStrings("changed:is:", in.filters[3]);
    try std.testing.expectEqual(Order.title_asc, in.order);
    try std.testing.expectEqual(@as(u32, 20), in.limit);
    const one = try list_in(arena, .{
        .types = &.{"post"},
    });
    try std.testing.expectEqualStrings("post", one.type.?);
    try std.testing.expectEqual(@as(usize, 0), one.filters.len);

    const own = try parse(arena, "type=post&status=draft");
    try std.testing.expect(own.type_view);
    const own_address = "/admin/content?type=post&status=is:draft";
    try std.testing.expectEqualStrings(own_address, try format(arena, own, null));
    try std.testing.expect(!(try parse(arena, "types=post")).type_view);
    try std.testing.expect(bare("type=order&page=2") and !bare("type=order&q=x"));

    const from_forms = try parse(arena, "type=order&field.total_operator=more&field.total=10" ++
        "&field.placed_operator=between&field.placed_from=2026-01-01" ++
        "&field.placed_to=2026-01-31&field.paid_operator=in_the_past&field.paid_count=7" ++
        "&field.paid_unit=d");
    try std.testing.expectEqual(@as(usize, 3), from_forms.clauses.len);
    try std.testing.expectEqualStrings("more", from_forms.clauses[0].operator);
    try std.testing.expectEqualStrings("10", from_forms.clauses[0].value);
    try std.testing.expectEqualStrings("2026-01-01..2026-01-31", from_forms.clauses[1].value);
    try std.testing.expectEqualStrings("7d", from_forms.clauses[2].value);

    const shaped = try parse(arena, "type=order&field.total=more:4999&field.total=at_least:10" ++
        "&field.at=before:10:30&field.empty=&order=-total&per_page=50&per_page=7" ++
        "&columns=number,,total");
    try std.testing.expectEqual(@as(usize, 3), shaped.clauses.len);
    try std.testing.expectEqualStrings("at_least", shaped.clauses[0].operator);
    try std.testing.expectEqualStrings("10:30", shaped.clauses[1].value);
    try std.testing.expectEqual(@as(?u32, null), shaped.per_page);
    try std.testing.expectEqual(@as(usize, 2), shaped.columns.?.len);
    const shaped_in = try list_in(arena, shaped);
    try std.testing.expectEqual(@as(usize, 2), shaped_in.filters.len);
    try std.testing.expectEqualStrings("-total", shaped_in.sort.?);
    try std.testing.expectEqualStrings(
        "/admin/content?type=order&field.total=at_least:10&field.at=before:10:30" ++
            "&field.empty=is:&order=-total&columns=number,total",
        try format(arena, shaped, null),
    );
    try std.testing.expect(!(try parse(arena, "type=post&type=page")).type_view);
}
