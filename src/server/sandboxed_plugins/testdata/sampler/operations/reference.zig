//! Draws the sampler's SDK reference: every top-level API it uses with its options under it,
//! the code that uses each, how to see it at work in the admin, and what to look for.
//!
//! The entries are `reference/catalog.json`; each entry's code is cut from the sampler's own
//! source as it draws, so it is the code that runs. Every entry is checked on every draw.
//!
//! Fails:
//! - Stale (409): an entry names a file or a declaration the sampler no longer has
//!
//! Example:
//!   in: { "query": "api=define" }
//!   out: { "html": "<!doctype html>" }
const publr = @import("publr");
const std = @import("std");

const code = @import("../reference/code.zig");
const sources = @import("../reference/sources.zig");

const catalog = @embedFile("../reference/catalog.json");
const try_script = @embedFile("../reference/try.js");

pub const In = struct {
    /// The address's query string: `api=<id>` opens that entry
    query: []const u8 = "",
    /// The path the project is served under
    base: []const u8 = "",
};

pub const Out = struct {
    /// The page's markup
    html: []const u8,
};

const Part = struct {
    file: []const u8,
    decl: []const u8,
};

/// One Run button: the operation it calls, as the person looking, and its input.
const Run = struct {
    label: []const u8,
    operation: []const u8,
    input: std.json.Value,
};

const Option = struct {
    name: []const u8,
    summary: []const u8,
    code: []const Part,
    see: []const []const u8,
    look_for: []const u8,
    runs: []const Run = &.{},
    tour: ?std.json.Value = null,
};

const Entry = struct {
    id: []const u8,
    group: []const u8,
    name: []const u8,
    summary: []const u8,
    code: []const Part,
    see: []const []const u8,
    look_for: []const u8,
    runs: []const Run = &.{},
    tour: ?std.json.Value = null,
    options: []const Option = &.{},
};

const View = publr.views.all.SamplerReference;
const Props = View.Props;
const Group = @typeInfo(@FieldType(Props, "groups")).pointer.child;
const Item = @typeInfo(@FieldType(Group, "items")).pointer.child;
const Code = @typeInfo(@FieldType(Props, "code")).pointer.child;
const Shown = @typeInfo(@FieldType(Props, "options")).pointer.child;
const ShownCode = @typeInfo(@FieldType(Shown, "code")).pointer.child;
const Button = @typeInfo(@FieldType(Props, "runs")).pointer.child;
const ShownButton = @typeInfo(@FieldType(Shown, "runs")).pointer.child;

pub const entries_max: u32 = 256;

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.query.len <= 4096);

    const entries = std.json.parseFromSliceLeaky([]const Entry, ctx.arena(), catalog, .{
        .ignore_unknown_fields = true,
    }) catch return ctx.fail(.Stale, "reference/catalog.json does not read.", .{});

    if (entries.len == 0 or entries.len > entries_max) {
        return ctx.fail(.Stale, "reference/catalog.json lists no entries.", .{});
    }

    try check_all(ctx, entries);

    const open = open_index(entries, asked(in.query));
    const entry = entries[open];

    const html = try publr.views.render(ctx, in.base, View, .{
        .groups = try groups_of(ctx, entries, open),
        .name = entry.name,
        .summary = entry.summary,
        .code = try cut_parts(ctx, Code, entry.id, entry.code),
        .see = entry.see,
        .look_for = entry.look_for,
        .key = "e",
        .runs = try buttons_of(ctx, Button, "e", entry.runs),
        .toured = entry.tour != null,
        .options = try options_of(ctx, entry),
    });

    return .{
        .html = try with_script(ctx, html, try data_of(ctx, entry)),
    };
}

/// Every entry's code and its options', cut from the source: a missing file or declaration
/// refuses the page, naming it, so the reference never shows code the sampler no longer has.
fn check_all(ctx: *publr.Ctx, entries: []const Entry) publr.Error!void {
    std.debug.assert(entries.len <= entries_max);

    for (entries) |entry| {
        _ = try cut_parts(ctx, Code, entry.id, entry.code);

        for (entry.options) |option| {
            _ = try cut_parts(ctx, ShownCode, entry.id, option.code);
        }
    }
}

/// `parts`, each cut from its file, as `Piece`s of the view.
fn cut_parts(
    ctx: *publr.Ctx,
    comptime Piece: type,
    id: []const u8,
    parts: []const Part,
) publr.Error![]const Piece {
    std.debug.assert(id.len > 0);
    std.debug.assert(parts.len <= 16);

    const cut = try ctx.alloc(Piece, @intCast(parts.len));

    for (parts, cut) |part, *made| {
        const source = sources.find(part.file) orelse {
            return ctx.fail(.Stale, "{id} names {file}, which the sampler does not have.", .{
                .id = id,
                .file = part.file,
            });
        };
        const text = code.cut(source, part.decl) orelse {
            return ctx.fail(.Stale, "{id} names {decl} in {file}, which is not there.", .{
                .id = id,
                .decl = part.decl,
                .file = part.file,
            });
        };

        made.* = .{
            .file = part.file,
            .text = text,
        };
    }

    return cut;
}

/// The entry's options as the view shows them.
fn options_of(ctx: *publr.Ctx, entry: Entry) publr.Error![]const Shown {
    std.debug.assert(entry.options.len <= 64);

    const shown = try ctx.alloc(Shown, @intCast(entry.options.len));

    for (entry.options, shown, 0..) |option, *made, position| {
        const index: u32 = @intCast(position);

        made.* = .{
            .name = option.name,
            .summary = option.summary,
            .code = try cut_parts(ctx, ShownCode, entry.id, option.code),
            .see = option.see,
            .look_for = option.look_for,
            .key = try key_of(ctx, index),
            .runs = try buttons_of(ctx, ShownButton, try key_of(ctx, index), option.runs),
            .toured = option.tour != null,
        };
    }

    return shown;
}

/// Option `index`'s key: where its answer and log show, `o<index>`.
fn key_of(ctx: *publr.Ctx, index: u32) publr.Error![]const u8 {
    std.debug.assert(index < 64);

    return ctx.print("o{d}", .{index});
}

/// A section's Run buttons: each labelled, its value `<key>:<position>`.
fn buttons_of(
    ctx: *publr.Ctx,
    comptime Shape: type,
    key: []const u8,
    runs: []const Run,
) publr.Error![]const Shape {
    std.debug.assert(key.len > 0);
    std.debug.assert(runs.len <= 16);

    const buttons = try ctx.alloc(Shape, @intCast(runs.len));

    for (runs, buttons, 0..) |run_one, *button, position| {
        button.* = .{
            .label = run_one.label,
            .value = try ctx.print("{s}:{d}", .{ key, position }),
        };
    }

    return buttons;
}

/// What the page's buttons do, as JSON: each Run's operation and input by its value, each
/// tour's steps by its section's key.
fn data_of(ctx: *publr.Ctx, entry: Entry) publr.Error![]const u8 {
    std.debug.assert(entry.options.len <= 64);

    var out: std.Io.Writer.Allocating = .init(ctx.arena());
    var json: std.json.Stringify = .{
        .writer = &out.writer,
    };

    write_data(ctx, &json, entry) catch return error.OutOfMemory;

    return out.written();
}

fn write_data(ctx: *publr.Ctx, json: *std.json.Stringify, entry: Entry) !void {
    std.debug.assert(entry.id.len > 0);

    try json.beginObject();
    try json.objectField("runs");
    try json.beginObject();
    try write_runs(json, "e", entry.runs);

    for (entry.options, 0..) |option, index| {
        try write_runs(json, try key_of(ctx, @intCast(index)), option.runs);
    }

    try json.endObject();
    try json.objectField("tours");
    try json.beginObject();

    if (entry.tour) |steps| {
        try json.objectField("e");
        try json.write(steps);
    }

    for (entry.options, 0..) |option, index| {
        if (option.tour) |steps| {
            try json.objectField(try key_of(ctx, @intCast(index)));
            try json.write(steps);
        }
    }

    try json.endObject();
    try json.endObject();
}

fn write_runs(json: *std.json.Stringify, key: []const u8, runs: []const Run) !void {
    std.debug.assert(key.len > 0);

    for (runs, 0..) |run_one, position| {
        var name: [32]u8 = undefined;

        try json.objectField(try std.fmt.bufPrint(&name, "{s}:{d}", .{ key, position }));
        try json.beginObject();
        try json.objectField("operation");
        try json.write(run_one.operation);
        try json.objectField("input");
        try json.write(run_one.input);
        try json.endObject();
    }
}

/// The page with its data and the Try it script, before its body closes. `</` in the data
/// is written `<\/`, so nothing in it ends the script early.
fn with_script(ctx: *publr.Ctx, html: []const u8, data: []const u8) publr.Error![]const u8 {
    std.debug.assert(html.len > 0);

    const end = std.mem.lastIndexOf(u8, html, "</body>") orelse html.len;
    const safe = std.mem.replaceOwned(u8, ctx.arena(), data, "</", "<\\/") catch {
        return error.OutOfMemory;
    };

    return ctx.print("{s}<script type=\"application/json\" id=\"sampler-data\">{s}</script>" ++
        "<script>{s}</script>{s}", .{ html[0..end], safe, try_script, html[end..] });
}

/// The id after `api=` in the query; empty for none.
fn asked(query: []const u8) []const u8 {
    std.debug.assert(query.len <= 4096);

    var pairs = std.mem.splitScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "api=")) {
            return pair["api=".len..];
        }
    }

    return "";
}

/// The entry with `id`, or the first.
fn open_index(entries: []const Entry, id: []const u8) u32 {
    std.debug.assert(entries.len > 0);

    for (entries, 0..) |entry, index| {
        if (publr.text.equals(entry.id, id)) {
            return @intCast(index);
        }
    }

    return 0;
}

/// The entries by group, in the catalog's order, each leading to `?api=<id>`.
fn groups_of(ctx: *publr.Ctx, entries: []const Entry, open: u32) publr.Error![]const Group {
    std.debug.assert(open < entries.len);

    var groups: std.ArrayList(Group) = .empty;
    var start: u32 = 0;

    while (start < entries.len) {
        var end = start;

        while (end < entries.len and publr.text.equals(entries[end].group, entries[start].group)) {
            end += 1;
        }

        const items = try ctx.alloc(Item, end - start);

        for (entries[start..end], items, start..) |entry, *item, index| {
            item.* = .{
                .label = entry.name,
                .href = try ctx.print("reference?api={s}", .{entry.id}),
                .current = index == open,
            };
        }

        groups.append(ctx.arena(), .{
            .label = entries[start].group,
            .items = items,
        }) catch return error.OutOfMemory;
        start = end;
    }

    return groups.items;
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "reference",
    .kind = .read,
    .run = run,
});
