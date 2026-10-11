//! Removal lists: what an agent asked to remove for good, waiting for its person. An agent
//! never removes: running a removal as a device puts it on the device's list instead, and
//! the person reviews the list, keeps what should stay and removes the rest, as themselves.

const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const registry = @import("../server/registry.zig");
const described = @import("removal/described.zig");
const ai_operations = @import("ai.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const removal = model.removal;
const lists = store.removals;

pub const namespace: sdk.operation.Namespace = .{
    .name = "removal",
    .summary = "Removal lists: what an agent asked to remove, for a person to confirm",
    .details =
    \\A device (an agent) never removes anything for good. When it runs a removal (purging a
    \\record, deleting a content type, removing a plugin), nothing is removed: the removal goes
    \\on the device's list, in words, for its person. The person reads the list, keeps what
    \\should stay, and removes the rest (`removal confirm`), as themselves, under their own
    \\permissions. Some things are never removed from a list (your own account): the list
    \\says how to do them by hand.
    ,
};

pub const operations = [_]type{ List, Get, Confirm, Decline };

const listed_failure_name = "ListedForRemoval";

/// A device's removal, put on its list instead of run: the call fails with where the list
/// is. What `sdk` calls for an operation that destroys, called by a device.
pub fn prepare(ctx: *Ctx, operation: []const u8, input: []const u8) Error {
    std.debug.assert(operation.len > 0);
    std.debug.assert(ctx.caller == .token);

    const device = ctx.caller.token;

    if (input.len > removal.input_len_max) {
        return error.Invalid;
    }

    const said = try described.of(ctx, operation, input);
    const conversation = try store.ai_conversations.by_device(ctx.db, ctx.arena, device.id);
    var transaction = try ctx.db.transaction();
    errdefer transaction.rollback();

    const list_id = try lists.open_for(ctx.db, ctx.io, ctx.arena, .{
        .user_id = device.user_id,
        .device_id = device.id,
        .conversation_id = conversation orelse "",
    }, ctx.now_ms);

    _ = try lists.add(ctx.db, list_id, .{
        .operation = operation,
        .input = input,
        .described = said,
    }, ctx.now_ms) orelse return ctx.fail(full);

    try transaction.commit();

    const message = std.fmt.allocPrint(ctx.arena, "Listed for removal: {s}. Not removed: " ++
        "the person reviews the list and confirms (/admin/removals/{s})", .{
        said.label,
        list_id,
    }) catch return error.OutOfMemory;

    return ctx.fail(.{
        .name = listed_failure_name,
        .status = 409,
        .message = message,
    });
}

const full: sdk.operation.Failure = .{
    .name = "ListFull",
    .status = 409,
    .message = "The removal list is full: the person reviews it first",
};

const no_device: sdk.operation.Failure = .{
    .name = "PersonOnly",
    .status = 403,
    .message = "A person confirms a removal list, never a device",
};

pub const Summary = struct {
    id: []const u8,
    state: []const u8,
    conversation_id: []const u8,
    /// Items still waiting for the person.
    waiting: u32,
    items: u32,
    created_at: i64,
};

pub const Item = struct {
    position: u32,
    operation: []const u8,
    label: []const u8,
    detail: []const u8,
    /// Why it never goes from a list, and how to remove it by hand; empty when it may.
    blocked: []const u8,
    /// `waiting`, `removed`, `trashed`, `kept`, `failed` or `blocked`.
    state: []const u8,
    message: []const u8,
};

const example_summary: Summary = .{
    .id = "0190a1b2c3d40001a1b2c3d4",
    .state = "waiting",
    .conversation_id = "",
    .waiting = 2,
    .items = 2,
    .created_at = 1789650000000,
};

pub const List = struct {
    pub const name = "removal.list";
    pub const description = "List the caller's removal lists, newest first";
    pub const details =
        \\Only the waiting ones unless `all`. A person's own lists; a device's person's.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        all: bool = false,
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        lists: []const Summary,
        total: u32 = 0,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .lists = &.{example_summary},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .all = "Done lists too",
        .limit = "How many at most; 50 when omitted, up to 50",
        .offset = "How many to pass over first: the next page's start",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .lists = "A page of the lists, newest first",
        .total = "How many there are in all",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const person = ctx.caller.user_id() orelse return error.Denied;

        if (in.limit == 0 or in.limit > lists.lists_max) {
            return error.Invalid;
        }

        const waiting_only = !in.all;
        const rows = try lists.list_by_user(
            ctx.db,
            ctx.arena,
            person,
            waiting_only,
            in.offset,
            in.limit,
        );
        const out = ctx.arena.alloc(Summary, rows.len) catch return error.OutOfMemory;

        for (rows, out) |row, *summary| {
            summary.* = try summary_of(ctx, row);
        }

        return .{
            .lists = out,
            .total = try lists.count_by_user(ctx.db, person, !in.all),
        };
    }
};

pub const Get = struct {
    pub const name = "removal.get";
    pub const description = "Read a removal list: every item, in words, and where it stands";
    pub const details =
        \\The caller's own lists only.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        list: Summary,
        items: []const Item,
    };
    pub const example: In = .{
        .id = example_summary.id,
    };
    pub const example_out: Out = .{
        .list = example_summary,
        .items = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The list's id",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .list = "The list",
        .items = "Its items in order",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const row = try own(ctx, in.id);
        const rows = try lists.items(ctx.db, ctx.arena, row.id);
        const out = ctx.arena.alloc(Item, rows.len) catch return error.OutOfMemory;

        for (rows, out) |item, *shown| {
            shown.* = .{
                .position = @intCast(item.position),
                .operation = item.operation,
                .label = item.label,
                .detail = item.detail,
                .blocked = item.blocked,
                .state = item.state,
                .message = item.message,
            };
        }

        return .{
            .list = try summary_of(ctx, row),
            .items = out,
        };
    }
};

pub const Confirm = struct {
    pub const name = "removal.confirm";
    pub const description = "Remove what a removal list holds, but what you keep";
    pub const details =
        \\Every waiting item runs as the caller, each through its own operation and its own
        \\permissions, except the positions in `keep`, which stay. Each item that fails says
        \\why; the rest go on. Then the list is done. A person only, never a device.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
        keep: []const u32 = &.{},
        trash: bool = false,
    };
    pub const Out = Get.Out;
    pub const example: In = .{
        .id = example_summary.id,
        .keep = &.{2},
    };
    pub const example_out: Out = Get.example_out;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The list's id",
        .keep = "The positions to keep; every other waiting item is removed",
        .trash = "Move records and terms to the trash instead (restorable); the rest go for good",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (ctx.caller == .token) {
            return ctx.fail(no_device);
        }

        const row = try own(ctx, in.id);

        if (removal.State.parse(row.state) != .waiting) {
            return error.Conflict;
        }

        for (try lists.items(ctx.db, ctx.arena, row.id)) |item| {
            try settle(ctx, row.id, item, contains(in.keep, @intCast(item.position)), in.trash);
        }

        try lists.close(ctx.db, row.id, ctx.now_ms);
        try carry_on(ctx, row);

        return Get.run(ctx, .{
            .id = row.id,
        }, granted);
    }
};

pub const Decline = struct {
    pub const name = "removal.decline";
    pub const description = "Keep everything a removal list holds";
    pub const details =
        \\Nothing is removed; the list is done. A person only, never a device.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const open = true;
    pub const example_signed_in = true;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = Get.Out;
    pub const example: In = .{
        .id = example_summary.id,
    };
    pub const example_out: Out = Get.example_out;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The list's id",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (ctx.caller == .token) {
            return ctx.fail(no_device);
        }

        const row = try own(ctx, in.id);

        if (removal.State.parse(row.state) != .waiting) {
            return error.Conflict;
        }

        for (try lists.items(ctx.db, ctx.arena, row.id)) |item| {
            if (removal.ItemState.parse(item.state) == .waiting) {
                try lists.settle(ctx.db, row.id, @intCast(item.position), .kept, "");
            }
        }

        try lists.close(ctx.db, row.id, ctx.now_ms);
        try carry_on(ctx, row);

        return Get.run(ctx, .{
            .id = row.id,
        }, granted);
    }
};

/// The conversation whose agent made the list, waiting for it: told what the person decided,
/// it carries on.
fn carry_on(ctx: *Ctx, row: lists.List) Error!void {
    std.debug.assert(row.id.len > 0);

    if (row.conversation_id.len == 0) {
        return;
    }

    const talk = store.ai_conversations.get(ctx.db, ctx.arena, row.conversation_id) catch {
        return;
    } orelse return;

    if (model.ai.State.parse(talk.state) != .waiting) {
        return;
    }

    _ = try registry.SDK.dispatch(ctx, ai_operations.Reply, .{
        .id = row.conversation_id,
        .prompt = try decided(ctx, row.id),
    });
}

/// What the person decided about a list, in words, for its agent.
fn decided(ctx: *Ctx, list_id: []const u8) Error![]const u8 {
    std.debug.assert(list_id.len > 0);

    var text: std.ArrayList(u8) = .empty;
    const writer = &text;

    try add(ctx, writer, "I went through the removal list myself; it is done.");

    for (try lists.items(ctx.db, ctx.arena, list_id)) |item| {
        const said = switch (removal.ItemState.parse(item.state) orelse continue) {
            .removed => "I removed it for good",
            .trashed => "I moved it to the trash",
            .kept => "I kept it",
            .failed => "It could not be removed",
            .blocked => "Left for me to do by hand",
            .waiting => continue,
        };
        const line = std.fmt.allocPrint(ctx.arena, "\n- {s}: {s}", .{ said, item.label }) catch {
            return error.OutOfMemory;
        };

        try add(ctx, writer, line);
    }

    try add(ctx, writer, "\nCarry on from here, with what is left.");

    return model.ai.clipped(text.items, model.ai.prompt_len_max);
}

fn add(ctx: *Ctx, text: *std.ArrayList(u8), words: []const u8) Error!void {
    std.debug.assert(words.len > 0);

    text.appendSlice(ctx.arena, words) catch return error.OutOfMemory;
}

/// The trash's counterpart of a removal for good, where there is one.
fn trashed_by(operation: []const u8) ?[]const u8 {
    std.debug.assert(operation.len > 0);

    if (std.mem.eql(u8, operation, "record.purge")) {
        return "record.delete";
    }

    if (std.mem.eql(u8, operation, "term.purge")) {
        return "term.delete";
    }

    return null;
}

/// One item decided: kept, or run as the caller (to the trash when asked and it may) and
/// removed or failed.
fn settle(
    ctx: *Ctx,
    list_id: []const u8,
    item: lists.Item,
    keep: bool,
    trash: bool,
) Error!void {
    std.debug.assert(list_id.len > 0);

    const position: u32 = @intCast(item.position);

    if (removal.ItemState.parse(item.state) != .waiting) {
        return;
    }

    if (keep) {
        return lists.settle(ctx.db, list_id, position, .kept, "");
    }

    ctx.failure = null;

    const instead = if (trash) trashed_by(item.operation) else null;
    const operation = instead orelse item.operation;

    _ = registry.SDK.call_json(ctx, operation, item.input) catch |err| {
        const why = if (ctx.failure) |failure| failure.message else @errorName(err);
        const message = model.ai.clipped(why, removal.detail_len_max);

        return lists.settle(ctx.db, list_id, position, .failed, message);
    };

    try lists.settle(ctx.db, list_id, position, if (instead != null) .trashed else .removed, "");
}

fn own(ctx: *Ctx, id: []const u8) Error!lists.List {
    std.debug.assert(lists.lists_max > 0);

    if (id.len == 0 or id.len > 64) {
        return error.Invalid;
    }

    const person = ctx.caller.user_id() orelse return error.Denied;
    const row = try lists.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

    if (!std.mem.eql(u8, row.user_id, person)) {
        return error.NotFound;
    }

    return row;
}

fn summary_of(ctx: *Ctx, row: lists.List) Error!Summary {
    std.debug.assert(row.id.len > 0);

    const counted = try lists.counts(ctx.db, row.id);

    std.debug.assert(counted.waiting <= counted.items);

    return .{
        .id = row.id,
        .state = row.state,
        .conversation_id = row.conversation_id,
        .waiting = counted.waiting,
        .items = counted.items,
        .created_at = row.created_at,
    };
}

fn contains(positions: []const u32, position: u32) bool {
    std.debug.assert(position > 0);

    for (positions) |kept| {
        if (kept == position) {
            return true;
        }
    }

    return false;
}
