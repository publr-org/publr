const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/internal/computed.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const internal = @import("../internal.zig");
const computed = @import("computed.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const records = store.internal_records;

/// The most pages one `sum` works computed values out over: a million records.
const pages_max: u32 = 5_000;
/// The parts a path to a number has at most: `size.tallies` is two.
const path_parts_max: u32 = 4;
const path_bytes_max: u32 = 256;

pub const Sum = struct {
    pub const shape = public.Sum;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if ((in.field == null) != (in.value == null)) {
            return error.Invalid;
        }

        var path_buffer: [path_bytes_max]u8 = undefined;
        const path = try json_path(&path_buffer, in.path);
        const target = try internal.scope_of(ctx, in.plugin, in.app, in.kind, false);

        const match = try internal.matching(target.collection, in.field, in.value);

        try internal.drawn_matched(ctx, target, match);

        const first = in.path[0 .. std.mem.indexOfScalar(u8, in.path, '.') orelse in.path.len];

        if (model.internal_record.computes(target.collection, first)) {
            try freshen_all(ctx, target, match);
        }

        return .{
            .sum = try records.sum(ctx.db, target.scope, match, path),
        };
    }
};

/// `$.size.tallies` from `size.tallies`: dotted names, nothing a path could say besides.
fn json_path(buffer: *[path_bytes_max]u8, path: []const u8) Error![]const u8 {
    std.debug.assert(path_parts_max > 0);
    std.debug.assert(buffer.len == path_bytes_max);

    if (path.len == 0 or path.len + 2 > path_bytes_max) {
        return error.Invalid;
    }

    var parts = std.mem.splitScalar(u8, path, '.');
    var count: u32 = 0;

    while (parts.next()) |part| {
        count += 1;

        const field_max = model.internal_record.field_len_max;

        if (count > path_parts_max or !model.internal_record.valid_name(part, field_max)) {
            return error.Invalid;
        }
    }

    return std.fmt.bufPrint(buffer, "$.{s}", .{path}) catch error.Invalid;
}

/// Every record matched read a page at a time, oldest first, its stale computed values
/// worked out and stored; each page's memory given back before the next.
fn freshen_all(ctx: *Ctx, target: internal.Target, match: ?records.Match) Error!void {
    std.debug.assert(target.collection.computed.len > 0);
    std.debug.assert(pages_max > 0);

    var after_buffer: [records.id_bytes_max]u8 = undefined;
    var after_len: u32 = 0;

    for (0..pages_max) |_| {
        var working = sdk.call_json.Working.begin(ctx) catch null;
        const page = freshen_page(ctx, target, match, after_buffer[0..after_len]);

        if (working) |*held| {
            held.end();

            const last = page catch |err| {
                try held.give_back_failed();

                return err;
            };

            @memcpy(after_buffer[0..last.len], last);
            after_len = @intCast(last.len);
            held.give_back();
        } else {
            const last = try page;

            @memcpy(after_buffer[0..last.len], last);
            after_len = @intCast(last.len);
        }

        if (after_len == 0) {
            return;
        }
    }

    return error.Invalid;
}

/// One page after `after`, freshened: the last id, empty after the last page.
fn freshen_page(
    ctx: *Ctx,
    target: internal.Target,
    match: ?records.Match,
    after: []const u8,
) Error![]const u8 {
    std.debug.assert(after.len <= records.id_bytes_max);
    std.debug.assert(target.scope.plugin.len > 0);

    const limit = sdk.operation.page_limit_max;
    const rows = try records.listed(ctx.db, ctx.arena, target.scope, match, .{
        .limit = limit,
        .oldest = true,
        .after = after,
    });

    try computed.freshen(ctx, target.scope, target.collection, rows);

    if (rows.len < limit) {
        return "";
    }

    return rows[rows.len - 1].id;
}

pub const HoldsUntil = struct {
    pub const shape = public.HoldsUntil;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.until_ms <= 0) {
            return error.Invalid;
        }

        if (ctx.computing_depth == 0) {
            return .{};
        }

        var buffer: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&buffer, "{s}{d}", .{
            computed.until_prefix,
            in.until_ms,
        }) catch return error.Invalid;

        ctx.depends_on(key);

        return .{};
    }
};

test "a path to a number is dotted names" {
    var buffer: [path_bytes_max]u8 = undefined;

    try std.testing.expectEqualStrings("$.size.tallies", try json_path(&buffer, "size.tallies"));
    try std.testing.expectError(error.Invalid, json_path(&buffer, ""));
    try std.testing.expectError(error.Invalid, json_path(&buffer, "size..tallies"));
    try std.testing.expectError(error.Invalid, json_path(&buffer, "size[0]"));
    try std.testing.expectError(error.Invalid, json_path(&buffer, "a.b.c.d.e"));
}
