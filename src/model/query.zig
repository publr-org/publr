const std = @import("std");

pub const clauses_max: u32 = 16;
pub const terms_max: u32 = 64;
pub const page_max: u32 = 200;
pub const text_bytes_max: u32 = 1024;
pub const Error = error{Invalid};
pub const Scalar = union(enum) { text: []const u8, integer: i64, real: f64 };
pub const Operator = enum { eq, ne, lt, lte, gt, gte };
pub const Filter = struct { field: []const u8, operator: Operator = .eq, value: Scalar };
pub const Membership = enum { any, all, none };
pub const Terms = struct {
    taxonomy: []const u8,
    ids: []const []const u8,
    match: Membership = .any,
};
pub const Reference = struct {
    field: []const u8,
    where: []const Filter,
    match: enum { any, none } = .any,
};
pub const Result = enum { page, count, groups };

// This is an experimental request contract, not a SQL or authorization interface.
pub const Request = struct {
    schema: []const u8,
    where: []const Filter = &.{},
    terms: []const Terms = &.{},
    references: []const Reference = &.{},
    result: Result = .page,
    group_by: ?[]const u8 = null,
    after_id: ?[]const u8 = null,
    limit: u32 = 20,
};

pub const Row = struct { key: Scalar, count: ?i64 = null };
pub const Response = struct {
    rows: []const Row,
    count: ?i64 = null,
    has_more: bool = false,
    next_id: ?[]const u8 = null,
};

pub fn validate(request: Request) Error!void {
    try name(request.schema);

    if (request.limit == 0 or request.limit > page_max) {
        return error.Invalid;
    }

    if (request.where.len + request.terms.len + request.references.len > clauses_max) {
        return error.Invalid;
    }

    if ((request.result == .groups) != (request.group_by != null)) {
        return error.Invalid;
    }

    if (request.group_by) |field| {
        try name(field);
    }

    if (request.after_id) |cursor| {
        if (request.result != .page) {
            return error.Invalid;
        }

        try identifier(cursor);
    }

    try filters(request.where);
    try memberships(request.terms);

    for (request.references) |reference| {
        try name(reference.field);
        try filters(reference.where);
    }

    std.debug.assert(request.limit <= page_max);
    std.debug.assert(request.result == .groups or request.group_by == null);
}

pub fn name(value: []const u8) Error!void {
    if (value.len == 0 or value.len > 64) {
        return error.Invalid;
    }

    for (value) |character| {
        if (!(std.ascii.isAlphanumeric(character) or character == '_')) {
            return error.Invalid;
        }
    }

    std.debug.assert(value.len <= 64);
}

fn identifier(value: []const u8) Error!void {
    if (value.len == 0 or value.len > 128) {
        return error.Invalid;
    }

    std.debug.assert(value.len > 0);
}

fn filters(values: []const Filter) Error!void {
    if (values.len > clauses_max) {
        return error.Invalid;
    }

    for (values) |filter| {
        try name(filter.field);

        switch (filter.value) {
            .text => |value| {
                if (value.len > text_bytes_max) {
                    return error.Invalid;
                }
            },
            .real => |value| {
                if (!std.math.isFinite(value)) {
                    return error.Invalid;
                }
            },
            .integer => {},
        }
    }

    std.debug.assert(values.len <= clauses_max);
}

fn memberships(values: []const Terms) Error!void {
    std.debug.assert(values.len <= clauses_max);

    for (values) |terms| {
        try name(terms.taxonomy);

        if (terms.ids.len == 0 or terms.ids.len > terms_max) {
            return error.Invalid;
        }

        for (terms.ids, 0..) |id, index| {
            try identifier(id);

            for (terms.ids[0..index]) |previous| {
                if (std.mem.eql(u8, id, previous)) {
                    return error.Invalid;
                }
            }
        }
    }
}

test "query contract rejects ambiguous shapes, duplicate terms and nonfinite numbers" {
    try validate(.{ .schema = "post" });
    try std.testing.expectError(error.Invalid, validate(.{ .schema = "post", .limit = 0 }));
    try std.testing.expectError(error.Invalid, validate(.{ .schema = "post;drop" }));
    try std.testing.expectError(error.Invalid, validate(.{ .schema = "post", .result = .groups }));
    try std.testing.expectError(error.Invalid, validate(.{
        .schema = "post",
        .terms = &.{.{ .taxonomy = "category", .ids = &.{ "a", "a" } }},
    }));
    try std.testing.expectError(error.Invalid, validate(.{
        .schema = "post",
        .where = &.{.{ .field = "price", .value = .{ .real = std.math.nan(f64) } }},
    }));
}

test "request limits and result mode combinations reject invalid input" {
    var fields: [clauses_max + 1]Filter = @splat(.{
        .field = "price",
        .value = .{ .integer = 1 },
    });
    try validate(.{ .schema = "post", .where = fields[0..clauses_max], .limit = page_max });
    try std.testing.expectError(error.Invalid, validate(.{
        .schema = "post",
        .where = &fields,
    }));
    try std.testing.expectError(error.Invalid, validate(.{
        .schema = "post",
        .references = &.{.{ .field = "authors", .where = &fields }},
    }));
    try std.testing.expectError(error.Invalid, validate(.{
        .schema = "post",
        .terms = &.{.{ .taxonomy = "categories", .ids = &.{} }},
    }));
    try std.testing.expectError(error.Invalid, validate(.{
        .schema = "post",
        .result = .count,
        .after_id = "p1",
    }));
    try std.testing.expectError(error.Invalid, validate(.{
        .schema = "post",
        .group_by = "price",
    }));
    const unknown = "{\"schema\":\"post\",\"raw_sql\":\"not permitted\"}";
    try std.testing.expectError(
        error.UnknownField,
        std.json.parseFromSlice(Request, std.testing.allocator, unknown, .{}),
    );
}
