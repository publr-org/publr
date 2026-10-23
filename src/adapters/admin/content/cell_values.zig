//! A list cell for any field: text and numbers as text, long and rich text as a short excerpt,
//! references (one or several, virtual ones too) as their records' titles linked, media as
//! thumbnails, users and terms by name, a repeater as how many items, a link or a place by
//! what it says. Every id a page's cells name is looked up once, before any is drawn.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const record_operations = @import("../../../operations/record.zig");
const media_operations = @import("../../../operations/media.zig");
const term_operations = @import("../../../operations/term.zig");
const user_operations = @import("../../../operations/user.zig");
const list = @import("list.zig");
const view_columns = @import("view_columns.zig");

const Error = admin.Error;
const Value = std.json.Value;
const Cell = admin.views.ContentList.CellsItem;
const Item = admin.views.ContentList.ItemsItem;
const Page = list.Page;

/// Ids a page looks up of each sort, and items one cell shows before "+N".
const ids_max: u32 = 200;
const items_shown_max: u32 = 3;
const excerpt_len_max: u32 = 80;

pub const Found = struct {
    label: []const u8,
    href: []const u8 = "",
    thumb: []const u8 = "",
};

/// What the page's cells name, by id.
pub const Lookups = struct {
    found: std.StringHashMapUnmanaged(Found) = .empty,
};

const Sort = enum { record, media, user, term, none };

fn sort_of(kind: []const u8) Sort {
    std.debug.assert(kind.len > 0);

    if (std.mem.eql(u8, kind, "reference") or std.mem.eql(u8, kind, "virtual")) {
        return .record;
    }

    return std.meta.stringToEnum(Sort, switch (kind[0]) {
        'm' => if (std.mem.eql(u8, kind, "media")) "media" else "none",
        'u' => if (std.mem.eql(u8, kind, "user")) "user" else "none",
        't' => if (std.mem.eql(u8, kind, "terms")) "term" else "none",
        else => "none",
    }).?;
}

/// The ids a value names: one id, a list of them, or the records a virtual field expanded.
fn ids_in(arena: std.mem.Allocator, value: Value) Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const items: []const Value = if (value == .array) value.array.items else &.{value};

    std.debug.assert(items.len <= 1 << 16);

    for (items) |item| {
        const id = switch (item) {
            .string => |text| text,
            .object => |object| if (object.get("_id")) |found| switch (found) {
                .string => |text| text,
                else => continue,
            } else continue,
            else => continue,
        };

        if (id.len > 0) {
            out.append(arena, id) catch return error.OutOfMemory;
        }
    }

    return out.items;
}

/// Every id the cells name, looked up: records' titles in one call, users' names in one,
/// media files and terms one by one, at most 200 of each.
pub fn gather(
    page: *const Page,
    fields: []const view_columns.Field,
    values: []const []const Value,
) Error!Lookups {
    std.debug.assert(page.session.signed_in());

    const arena = page.session.arena;
    var wanted: [4]std.ArrayList([]const u8) = .{ .empty, .empty, .empty, .empty };
    var lookups: Lookups = .{};

    for (values) |row| {
        for (fields, row) |field, value| {
            const sort = sort_of(field.kind);

            if (sort == .none or value == .null) {
                continue;
            }

            const bucket = &wanted[@intFromEnum(sort)];

            for (try ids_in(arena, value)) |id| {
                if (bucket.items.len < ids_max) {
                    bucket.append(arena, id) catch return error.OutOfMemory;
                }
            }
        }
    }

    try records_into(page, wanted[@intFromEnum(Sort.record)].items, &lookups);
    try media_into(page, wanted[@intFromEnum(Sort.media)].items, &lookups);
    try users_into(page, wanted[@intFromEnum(Sort.user)].items, &lookups);
    try terms_into(page, wanted[@intFromEnum(Sort.term)].items, &lookups);

    return lookups;
}

fn put(page: *const Page, lookups: *Lookups, id: []const u8, found: Found) Error!void {
    std.debug.assert(id.len > 0);

    lookups.found.put(page.session.arena, id, found) catch return error.OutOfMemory;
}

fn records_into(page: *const Page, ids: []const []const u8, lookups: *Lookups) Error!void {
    std.debug.assert(ids.len <= ids_max);

    if (ids.len == 0) {
        return;
    }

    var reading = page.session.*;
    const shown = registry.SDK.dispatch(&reading.ctx, record_operations.Shown, .{
        .ids = ids,
        .limit = ids_max,
        .purpose = .edit,
    }) catch return;

    for (shown.titles) |title| {
        try put(page, lookups, title.id, .{
            .label = title.title,
            .href = try std.fmt.allocPrint(page.session.arena, "/admin/content/{s}", .{title.id}),
        });
    }
}

fn media_into(page: *const Page, ids: []const []const u8, lookups: *Lookups) Error!void {
    std.debug.assert(ids.len <= ids_max);

    const arena = page.session.arena;

    for (ids) |id| {
        if (lookups.found.contains(id)) {
            continue;
        }

        var reading = page.session.*;
        const got = registry.SDK.dispatch(&reading.ctx, media_operations.Get, .{
            .id = id,
        }) catch continue;
        const file = got.media;
        const image = std.mem.eql(u8, file.family, "image") and !file.missing;

        try put(page, lookups, id, .{
            .label = if (file.title.len > 0) file.title else file.filename,
            .href = try std.fmt.allocPrint(arena, "/admin/media/{s}", .{id}),
            .thumb = if (image)
                try std.fmt.allocPrint(arena, "/media/{s}?w=96&h=96&fit=cover", .{file.key})
            else
                "",
        });
    }
}

fn users_into(page: *const Page, ids: []const []const u8, lookups: *Lookups) Error!void {
    std.debug.assert(ids.len <= ids_max);

    if (ids.len == 0) {
        return;
    }

    var reading = page.session.*;
    const options = registry.SDK.dispatch(&reading.ctx, user_operations.Options, .{
        .limit = ids_max,
    }) catch return;

    for (options.users) |user| {
        if (contains(ids, user.id)) {
            try put(page, lookups, user.id, .{
                .label = user.label,
            });
        }
    }
}

fn terms_into(page: *const Page, ids: []const []const u8, lookups: *Lookups) Error!void {
    std.debug.assert(ids.len <= ids_max);

    for (ids) |id| {
        if (lookups.found.contains(id)) {
            continue;
        }

        var reading = page.session.*;
        const got = registry.SDK.dispatch(&reading.ctx, term_operations.Get, .{
            .id = id,
            .purpose = .edit,
        }) catch continue;

        try put(page, lookups, id, .{
            .label = got.term.title,
        });
    }
}

/// The cell of one field's value.
pub fn cell(
    page: *const Page,
    lookups: *const Lookups,
    field: view_columns.Field,
    value: Value,
) Error!Cell {
    std.debug.assert(field.name.len > 0);

    const arena = page.session.arena;
    var out = blank(field.name);
    const sort = sort_of(field.kind);

    if (value == .null) {
        return out;
    }

    if (sort != .none) {
        const ids = try ids_in(arena, value);
        var items: std.ArrayList(Item) = .empty;

        for (ids, 0..) |id, position| {
            if (position == items_shown_max) {
                break;
            }

            const found = lookups.found.get(id) orelse continue;

            items.append(arena, .{
                .id = id,
                .label = found.label,
                .href = found.href,
                .thumb = found.thumb,
            }) catch return error.OutOfMemory;
        }

        out.kind = if (sort == .media) "thumbs" else "links";
        out.items = items.items;
        out.text = if (ids.len > items_shown_max)
            try std.fmt.allocPrint(arena, "+{d}", .{ids.len - items_shown_max})
        else
            "";

        return out;
    }

    out.text = try text_of(page, field.kind, value);
    out.kind = if (std.mem.eql(u8, field.kind, "money") or std.mem.eql(u8, field.kind, "integer") or
        std.mem.eql(u8, field.kind, "number")) "amount" else "text";

    return out;
}

/// A value with no ids in it as text: an excerpt of long text, a count of items, what a
/// link or a place says, several plain values joined.
fn text_of(page: *const Page, kind: []const u8, value: Value) Error![]const u8 {
    std.debug.assert(kind.len > 0);

    const session = page.session;
    const arena = session.arena;

    // A plugin's kind reads as its `.text` says.
    if (model.kinds.lookup(registry.kinds(&session.ctx), kind).text) |text| {
        return excerpt(arena, text(&session.ctx, kind, value) orelse "");
    }

    if (model.field.is_repeater(kind) and value == .array) {
        const count: u32 = @intCast(value.array.items.len);

        return session.translated_count("{count} item", "{count} items", count);
    }

    if (value == .object) {
        return object_text(arena, kind, value);
    }

    if (value == .array) {
        var parts: std.ArrayList([]const u8) = .empty;

        for (value.array.items) |item| {
            const text = try view_columns.text_of(arena, kind, item);

            if (text.len > 0) {
                parts.append(arena, text) catch return error.OutOfMemory;
            }
        }

        return std.mem.join(arena, ", ", parts.items) catch return error.OutOfMemory;
    }

    if (value == .string and (std.mem.eql(u8, kind, "richtext") or std.mem.eql(u8, kind, "text"))) {
        return excerpt(arena, value.string);
    }

    return view_columns.text_of(arena, kind, value);
}

/// A link's label or address, a place's address, a group's first words, money.
fn object_text(arena: std.mem.Allocator, kind: []const u8, value: Value) Error![]const u8 {
    std.debug.assert(value == .object);

    if (std.mem.eql(u8, kind, "money")) {
        return view_columns.text_of(arena, kind, value);
    }

    for ([_][]const u8{ "label", "address", "title", "name", "url" }) |key| {
        const found = value.object.get(key) orelse continue;

        if (found == .string and found.string.len > 0) {
            return excerpt(arena, found.string);
        }
    }

    var entries = value.object.iterator();

    while (entries.next()) |entry| {
        if (entry.value_ptr.* == .string and entry.value_ptr.string.len > 0) {
            return excerpt(arena, entry.value_ptr.string);
        }
    }

    return "";
}

/// Text without markup, the first words of it: `<p>Black tea with…</p>` as
/// `Black tea with…`.
pub fn excerpt(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    std.debug.assert(excerpt_len_max > 0);

    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    var spaced = true;

    for (text) |byte| {
        if (out.items.len >= excerpt_len_max) {
            out.appendSlice(arena, "…") catch return error.OutOfMemory;
            break;
        }

        if (byte == '<') {
            in_tag = true;
        } else if (byte == '>') {
            in_tag = false;
            byte_space(arena, &out, &spaced) catch return error.OutOfMemory;
        } else if (!in_tag) {
            if (std.ascii.isWhitespace(byte)) {
                byte_space(arena, &out, &spaced) catch return error.OutOfMemory;
            } else {
                out.append(arena, byte) catch return error.OutOfMemory;
                spaced = false;
            }
        }
    }

    return std.mem.trim(u8, out.items, " ");
}

fn byte_space(arena: std.mem.Allocator, out: *std.ArrayList(u8), spaced: *bool) !void {
    std.debug.assert(out.items.len <= excerpt_len_max + 4);

    if (!spaced.*) {
        try out.append(arena, ' ');
        spaced.* = true;
    }
}

fn blank(id: []const u8) Cell {
    std.debug.assert(id.len > 0);

    return .{
        .id = id,
        .text = "",
        .href = "",
        .kind = "text",
        .tone = "neutral",
        .extra = "",
        .extra_tone = "neutral",
        .items = &.{},
    };
}

fn contains(ids: []const []const u8, id: []const u8) bool {
    std.debug.assert(id.len > 0);

    for (ids) |candidate| {
        if (std.mem.eql(u8, candidate, id)) {
            return true;
        }
    }

    return false;
}

test "an excerpt drops markup and keeps the first words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Black tea with bergamot.", try excerpt(
        arena,
        "<p>Black tea</p><p>with  bergamot.</p>",
    ));
    try std.testing.expectEqualStrings("", try excerpt(arena, "<br>"));
    const long = "a " ** 100;
    try std.testing.expect(std.mem.endsWith(u8, try excerpt(arena, long), "…"));
}
