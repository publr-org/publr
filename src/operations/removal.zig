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
const public = @import("../publr/operations/removal.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const removal = model.removal;
const lists = store.removals;

pub const namespace = public.namespace;

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

pub const Summary = public.Summary;
pub const Item = public.Item;
const example_summary = public.example_summary;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Confirm;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.Decline;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const example_signed_in = shape.example_signed_in;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
