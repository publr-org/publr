//! Broken references worked out from the references themselves: every pointer a reference
//! field holds at a record in the trash, gone for good, or of a type the holder's app no
//! longer reaches, one case per record pointed at (and per app, for a type not shared).
//! The pointers are read a chunk at a time in the order of their target, and a case is
//! held in its own fixed memory while its target's pointers are read, so a reading of
//! every case takes one chunk's memory, however many pointers there are.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Brief = store.content_types.Brief;
const Link = store.values.Link;
const LinkKey = store.values.LinkKey;

pub const Reason = enum { deleted, gone, not_shared };

/// The records pointing at a case it names, the first of them; `holders_total` counts all.
pub const holders_shown_max: u32 = 10;
/// Small under test, so a case's pointers and a page of cases cross chunks there.
const chunk_links: u32 = if (@import("builtin").is_test) 4 else 256;
/// The apps whose records lost one target's type: past these, a target's further apps are
/// not cases.
const apps_per_target_max: u32 = 32;
const id_len_max = model.validate.id_len_max;
const app_len_max = model.app.name_len_max;
const field_len_max: u32 = 256;

pub const Holder = struct {
    id: []const u8,
    type: []const u8,
    title: []const u8,
};

pub const Case = struct {
    target: []const u8,
    /// Its type's handle; empty when it is gone for good.
    type: []const u8,
    title: []const u8,
    reason: Reason,
    /// For `not_shared`, the app whose records point at it; empty otherwise.
    app: []const u8,
    /// The first records pointing at it, up to `holders_shown_max`.
    holders: []const Holder,
    /// How many records point at it.
    holders_total: u32,
    kept: bool,
};

pub const example: Case = .{
    .target = "a1b2c3d4e5f60718293a4b5c",
    .type = "stock",
    .title = "Blue mug",
    .reason = .not_shared,
    .app = "www",
    .holders = &.{.{
        .id = "b2c3d4e5f60718293a4b5c6d",
        .type = "product",
        .title = "Mug",
    }},
    .holders_total = 1,
    .kept = false,
};

/// What a reading wants: titles to show, or only what counting needs.
pub const Detail = enum { titles, count };

/// Where a reading begins: after a target (empty for the first), or at one, and only it.
pub const Start = union(enum) {
    after: []const u8,
    only: []const u8,
};

/// Text kept past the chunk it was read from.
fn Fixed(comptime len_max: u32) type {
    return struct {
        bytes: [len_max]u8 = undefined,
        len: u32 = 0,

        const Self = @This();

        fn set(fixed: *Self, value: []const u8) void {
            std.debug.assert(value.len <= len_max);

            @memcpy(fixed.bytes[0..value.len], value);
            fixed.len = @intCast(value.len);
        }

        fn text(fixed: *const Self) []const u8 {
            std.debug.assert(fixed.len <= len_max);

            return fixed.bytes[0..fixed.len];
        }
    };
}

const Held = struct {
    id: Fixed(id_len_max) = .{},
    type_id: Fixed(id_len_max) = .{},
};

/// A case while its target's pointers are read.
const Open = struct {
    target: Fixed(id_len_max) = .{},
    target_type: Fixed(id_len_max) = .{},
    app: Fixed(app_len_max) = .{},
    reason: Reason = .gone,
    holders: [holders_shown_max]Held = undefined,
    holders_shown: u32 = 0,
    holders_total: u32 = 0,
    last_holder: Fixed(id_len_max) = .{},

    fn hold(open: *Open, link: Link) void {
        std.debug.assert(link.holder.len > 0);

        if (open.holders_total > 0 and std.mem.eql(u8, open.last_holder.text(), link.holder)) {
            return;
        }

        open.last_holder.set(link.holder);
        open.holders_total += 1;

        if (open.holders_shown < holders_shown_max) {
            open.holders[open.holders_shown] = .{};
            open.holders[open.holders_shown].id.set(link.holder);
            open.holders[open.holders_shown].type_id.set(link.holder_type);
            open.holders_shown += 1;
        }

        std.debug.assert(open.holders_shown <= open.holders_total);
    }
};

/// The cases of one target, open while its pointers are read.
const Target = struct {
    opens: [apps_per_target_max]Open = undefined,
    len: u32 = 0,

    fn target(held: *const Target) []const u8 {
        std.debug.assert(held.len > 0);

        return held.opens[0].target.text();
    }

    fn open_for(held: *Target, link: Link, found: Broken) ?*Open {
        std.debug.assert(link.target.len > 0);

        for (held.opens[0..held.len]) |*open| {
            if (std.mem.eql(u8, open.app.text(), found.app)) {
                return open;
            }
        }

        if (held.len == apps_per_target_max) {
            return null;
        }

        const open = &held.opens[held.len];

        held.len += 1;
        open.* = .{
            .reason = found.reason,
        };
        open.target.set(link.target);
        open.target_type.set(link.target_type);
        open.app.set(found.app);

        return open;
    }
};

/// Each case in the order of the record pointed at, from `start`, handed to `visit` until
/// it answers false. A case handed over lives only during the call: what is kept of it is
/// copied (`kept_copy`).
pub fn walk(
    ctx: *Ctx,
    detail: Detail,
    start: Start,
    visitor: anytype,
    comptime visit: fn (@TypeOf(visitor), *Ctx, Case) Error!bool,
) Error!void {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(chunk_links <= store.values.links_max);

    var types: Types = .{
        .ctx = ctx,
    };
    const scratch = try ctx.scratch();
    var held: Target = .{};
    var key_target: Fixed(id_len_max) = .{};
    var key_holder: Fixed(id_len_max) = .{};
    var key_field: Fixed(field_len_max) = .{};

    switch (start) {
        // Past every holder of the target: hex ids sort before `~`.
        .after => |target| {
            key_target.set(target);
            key_holder.set(if (target.len > 0) "~" else "");
        },
        .only => |target| key_target.set(target),
    }

    while (true) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const links = store.values.suspect_links(ctx.db, scratch.allocator(), .{
            .target = key_target.text(),
            .holder = key_holder.text(),
            .field = key_field.text(),
        }, chunk_links) catch return error.Failed;

        for (links) |link| {
            if (held.len > 0 and !std.mem.eql(u8, held.target(), link.target)) {
                if (!try emit(ctx, &held, &types, detail, visitor, visit)) {
                    return;
                }
            }

            if (start == .only and !std.mem.eql(u8, link.target, start.only)) {
                return;
            }

            const found = try broken(&types, link) orelse continue;
            const open = held.open_for(link, found) orelse continue;

            open.hold(link);
        }

        if (links.len < chunk_links) {
            break;
        }

        const last = links[links.len - 1];

        key_target.set(last.target);
        key_holder.set(last.holder);
        key_field.set(last.field);
    }

    _ = try emit(ctx, &held, &types, detail, visitor, visit);
}

/// The open cases of a target handed over, then closed; false when `visit` stopped.
fn emit(
    ctx: *Ctx,
    held: *Target,
    types: *Types,
    detail: Detail,
    visitor: anytype,
    comptime visit: fn (@TypeOf(visitor), *Ctx, Case) Error!bool,
) Error!bool {
    std.debug.assert(held.len <= apps_per_target_max);

    defer held.len = 0;

    for (held.opens[0..held.len]) |*open| {
        var holders: [holders_shown_max]Holder = undefined;

        for (open.holders[0..open.holders_shown], holders[0..open.holders_shown]) |*from, *to| {
            to.* = .{
                .id = from.id.text(),
                .type = if (try types.of(from.type_id.text())) |brief| brief.handle else "",
                .title = if (detail == .titles) try title_of(ctx, from.id.text()) else "",
            };
        }

        const target = open.target.text();
        const with_title = detail == .titles and open.reason != .gone;
        const case: Case = .{
            .target = target,
            .type = if (try types.of(open.target_type.text())) |brief| brief.handle else "",
            .title = if (with_title) try title_of(ctx, target) else "",
            .reason = open.reason,
            .app = open.app.text(),
            .holders = holders[0..open.holders_shown],
            .holders_total = open.holders_total,
            .kept = try kept_now(ctx, open),
        };

        if (!try visit(visitor, ctx, case)) {
            return false;
        }
    }

    return true;
}

/// A case handed over by `walk`, copied to last past the call.
pub fn kept_copy(arena: std.mem.Allocator, case: Case) Error!Case {
    std.debug.assert(case.target.len > 0);
    std.debug.assert(case.holders.len <= holders_shown_max);

    const holders = try arena.alloc(Holder, case.holders.len);

    for (case.holders, holders) |from, *to| {
        to.* = .{
            .id = try arena.dupe(u8, from.id),
            .type = try arena.dupe(u8, from.type),
            .title = try arena.dupe(u8, from.title),
        };
    }

    return .{
        .target = try arena.dupe(u8, case.target),
        .type = try arena.dupe(u8, case.type),
        .title = try arena.dupe(u8, case.title),
        .reason = case.reason,
        .app = try arena.dupe(u8, case.app),
        .holders = holders,
        .holders_total = case.holders_total,
        .kept = case.kept,
    };
}

/// A case handed over by `walk`, copied with the titles of its record and its holders.
pub fn titled(ctx: *Ctx, case: Case) Error!Case {
    std.debug.assert(case.target.len > 0);
    std.debug.assert(case.holders.len <= holders_shown_max);

    var copy = try kept_copy(ctx.arena, case);
    const holders = try ctx.arena.dupe(Holder, copy.holders);

    for (holders) |*holder| {
        holder.title = try title_of(ctx, holder.id);
    }

    copy.holders = holders;
    copy.title = if (case.reason == .gone) "" else try title_of(ctx, case.target);

    return copy;
}

/// The case at `target` for `app`; null when there is none.
pub fn find(ctx: *Ctx, target: []const u8, app: []const u8) Error!?Case {
    std.debug.assert(target.len > 0);
    std.debug.assert(app.len <= app_len_max);

    const Finder = struct {
        app: []const u8,
        found: ?Case = null,

        fn visit(finder: *@This(), inner: *Ctx, case: Case) Error!bool {
            std.debug.assert(case.target.len > 0);

            if (!std.mem.eql(u8, case.app, finder.app)) {
                return true;
            }

            finder.found = try kept_copy(inner.arena, case);

            return false;
        }
    };
    var finder: Finder = .{
        .app = app,
    };

    try walk(ctx, .count, .{
        .only = target,
    }, &finder, Finder.visit);

    return finder.found;
}

/// Each record of the case at `target` for `app` handed to `visit`, however many there
/// are, a chunk of pointers at a time.
pub fn each_holder(
    ctx: *Ctx,
    target: []const u8,
    app: []const u8,
    visitor: anytype,
    comptime visit: fn (@TypeOf(visitor), *Ctx, []const u8) Error!void,
) Error!void {
    std.debug.assert(target.len > 0);
    std.debug.assert(app.len <= app_len_max);

    var types: Types = .{
        .ctx = ctx,
    };
    const scratch = try ctx.scratch();
    var key_holder: Fixed(id_len_max) = .{};
    var key_field: Fixed(field_len_max) = .{};
    var last_holder: Fixed(id_len_max) = .{};

    while (true) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const links = store.values.suspect_links(ctx.db, scratch.allocator(), .{
            .target = target,
            .holder = key_holder.text(),
            .field = key_field.text(),
        }, chunk_links) catch return error.Failed;

        for (links) |link| {
            if (!std.mem.eql(u8, link.target, target)) {
                return;
            }

            const found = try broken(&types, link) orelse continue;

            const seen = std.mem.eql(u8, last_holder.text(), link.holder);

            if (!std.mem.eql(u8, found.app, app) or seen) {
                continue;
            }

            last_holder.set(link.holder);
            try visit(visitor, ctx, link.holder);
        }

        if (links.len < chunk_links) {
            return;
        }

        key_holder.set(links[links.len - 1].holder);
        key_field.set(links[links.len - 1].field);
    }
}

const Broken = struct {
    reason: Reason,
    app: []const u8,
};

/// Why a pointer is broken, and for a type not shared the app that lost it; null when it
/// is not: at a library file, or at another type its app reaches.
fn broken(types: *Types, link: Link) Error!?Broken {
    std.debug.assert(link.holder.len > 0);
    std.debug.assert(link.target.len > 0);

    const holder = try types.of(link.holder_type) orelse return null;

    if (link.target_type.len == 0) {
        return .{
            .reason = .gone,
            .app = "",
        };
    }

    if (std.mem.eql(u8, link.target_status, "trashed")) {
        return .{
            .reason = .deleted,
            .app = "",
        };
    }

    const target = try types.of(link.target_type) orelse return null;

    if (target.kind == .media) {
        return null;
    }

    const shared = model.content_type.shared_of(.{
        .handle = target.handle,
        .name = target.name,
        .app = target.app,
        .shared = target.shared,
        .fields = &.{},
    });
    const reached = if (holder.app.len == 0)
        target.app.len == 0
    else
        model.content_type.reaches(target.app, shared, holder.app);

    if (reached) {
        return null;
    }

    return .{
        .reason = .not_shared,
        .app = holder.app,
    };
}

fn title_of(ctx: *Ctx, id: []const u8) Error![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const row = store.records.get(ctx.db, ctx.arena, id) catch return error.Failed;

    return if (row) |found| found.title else "";
}

/// Kept, and nothing about it changed since: the same reason, as many records pointing.
fn kept_now(ctx: *Ctx, open: *const Open) Error!bool {
    std.debug.assert(open.target.len > 0);
    std.debug.assert(open.holders_total > 0);

    var buffer: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    const row = store.health_kept.find(
        ctx.db,
        fixed.allocator(),
        open.target.text(),
        open.app.text(),
    ) catch return error.Failed;
    const kept = row orelse return false;

    const same_reason = std.mem.eql(u8, kept.reason, @tagName(open.reason));

    return same_reason and kept.holders == open.holders_total;
}

/// The types the pointers name, each read the first time it is asked for and kept for the
/// rest of the reading: as many as the pointers name, never every type.
const Types = struct {
    ctx: *Ctx,
    known: std.StringHashMapUnmanaged(?Brief) = .empty,

    fn of(types: *Types, id: []const u8) Error!?Brief {
        if (id.len == 0) {
            return null;
        }

        if (types.known.get(id)) |known| {
            return known;
        }

        const arena = types.ctx.arena;
        const found = store.content_types.brief_by_id(types.ctx.db, arena, id) catch {
            return error.Failed;
        };

        try types.known.put(arena, try arena.dupe(u8, id), found);

        std.debug.assert(types.known.contains(id));

        return found;
    }
};
