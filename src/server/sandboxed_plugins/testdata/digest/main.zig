//! Lists what is on the site, for a weekly digest.
//!
//! A plugin only ever installed that reads across types and taxonomies under its grants:
//! posts as a visitor sees them, its own notes drafts and all (it writes them), and terms of
//! every taxonomy, private ones and drafts once an administrator switches those flags on.
const std = @import("std");
const publr = @import("publr");

const record = publr.operations.record;
const term = publr.operations.term;

const manifest: publr.Manifest = .{
    .name = "digest",
    .version = "0.1.0",
};

pub const ReadIn = struct {
    /// Asked for nothing in particular: every field is optional
    week: u32 = 0,
};

pub const ReadOut = struct {
    /// The titles `record.list` answers over posts and notes, by title
    listed: []const []const u8,
    /// The titles a GROQ query over posts and notes answers, by title
    queried: []const []const u8,
    /// The names of the terms `term.list` answers, by name
    terms: []const []const u8,
};

/// Lists the posts, notes and terms the digest may read.
///
/// Example:
///   in: { "week": 1 }
///   out: { "listed": ["Post live"], "queried": ["Post live"], "terms": ["News"] }
pub const Read = publr.operation.define(ReadIn, ReadOut, .{
    .name = "read",
    .kind = .read,
    .run = read,
});

const Titled = struct {
    title: []const u8,
};

fn read(ctx: *publr.Ctx, in: ReadIn) publr.Error!ReadOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.week > 53) {
        return error.Invalid;
    }

    const arena = ctx.arena();
    const listed = try ctx.call(record.List, .{
        .types = &.{ "post", "note" },
        .order = .title_asc,
    });
    const queried = try ctx.call(record.Query, .{
        .query = "*[_type in [\"post\", \"note\"]] | order(title asc) { title }",
    });
    const rows = std.json.parseFromSliceLeaky([]const Titled, arena, queried.result.text, .{
        .ignore_unknown_fields = true,
    }) catch return error.Invalid;
    // With terms.read switched off the digest goes out without terms.
    const terms = ctx.call(term.List, .{
        .order = .title_asc,
    }) catch |err| switch (err) {
        error.Denied => term.List.Out{
            .terms = &.{},
        },
        else => return err,
    };
    const out: ReadOut = .{
        .listed = try titles(arena, listed.records),
        .queried = try titled(arena, rows),
        .terms = try titles(arena, terms.terms),
    };

    std.debug.assert(out.listed.len <= 50);

    return out;
}

fn titles(arena: std.mem.Allocator, rows: []const record.Record) publr.Error![]const []const u8 {
    std.debug.assert(rows.len <= 1000);

    const out = arena.alloc([]const u8, rows.len) catch return error.OutOfMemory;

    for (rows, out) |row, *title| {
        title.* = row.title;
    }

    return out;
}

fn titled(arena: std.mem.Allocator, rows: []const Titled) publr.Error![]const []const u8 {
    std.debug.assert(rows.len <= 1000);

    const out = arena.alloc([]const u8, rows.len) catch return error.OutOfMemory;

    for (rows, out) |row, *title| {
        title.* = row.title;
    }

    return out;
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{Read},
    .permissions = &.{ .{
        .key = "records.read",
        .reason = "Lists what visitors see, for the digest",
    }, .{
        .key = "records.write",
        .records = &.{"note"},
        .reason = "Keeps its notes on the digest",
    }, .{
        .key = "terms.read",
        .drafts = true,
        .private = true,
        .reason = "Lists every taxonomy's terms, the staff's too",
    } },
});
