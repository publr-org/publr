//! Puts prices on the site.
//!
//! A plugin only ever installed, writing another type's records: notes the site keeps. It asks
//! for `records.write` on `note` with `.publish`, so an administrator can switch `.publish` off
//! and watch its new notes wait for approval, then switch it back on. It withdraws a note
//! for good only from its `.destructive` operation, for an administrator.
const std = @import("std");
const publr = @import("publr");

const record = publr.operations.record;

const manifest: publr.Manifest = .{
    .name = "prices",
    .version = "0.1.0",
};

const operations = [_]type{ Post, Withdraw };

pub const PostIn = struct {
    /// The price, as the note's title
    title: []const u8,
};

pub const PostOut = struct {
    /// The note's id
    id: []const u8,
    /// Its status now
    status: []const u8,
    /// Waiting for someone who may publish.
    pending: bool,
    /// Whether the plugin may put it live itself.
    publish: bool,
};

/// Post a price as a note, and put it live
///
/// Example:
///   in: { "title": "Apples 2.40" }
///   out: { "id": "0190a1b2c3d40001a1b2c3d4", "status": "published", "pending": false,
///          "publish": true }
pub const Post = publr.operation.define(PostIn, PostOut, .{
    .name = "post",
    .kind = .write,
    .run = post,
});

fn post(ctx: *publr.Ctx, in: PostIn) publr.Error!PostOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.title.len == 0 or in.title.len > 200) {
        return error.Invalid;
    }

    const document = std.json.Stringify.valueAlloc(ctx.arena(), .{
        .title = in.title,
    }, .{}) catch return error.OutOfMemory;
    const created = try ctx.call(record.Create, .{
        .type = "note",
        .document = document,
    });
    const moved = try ctx.call(record.Transition, .{
        .id = created.id,
        .transition = "publish",
    });

    return .{
        .id = created.id,
        .status = moved.status,
        .pending = moved.pending,
        .publish = ctx.grant("records.write").publish,
    };
}

pub const WithdrawIn = struct {
    /// The note, by id
    id: []const u8,
};

pub const WithdrawOut = struct {
    /// `destroyed`, or `trashed` while it waits for a person who may destroy it
    status: []const u8,
};

/// Withdraws a price for good: its note goes to the trash and is destroyed.
///
/// Administrators may call it.
///
/// Example:
///   in: { "id": "0190a1b2c3d40001a1b2c3d4" }
///   out: { "status": "destroyed" }
pub const Withdraw = publr.operation.define(WithdrawIn, WithdrawOut, .{
    .name = "withdraw",
    .kind = .write,
    .destructive = true,
    .run = withdraw,
});

fn withdraw(ctx: *publr.Ctx, in: WithdrawIn) publr.Error!WithdrawOut {
    std.debug.assert(in.id.len > 0);

    _ = try ctx.call(record.Transition, .{
        .id = in.id,
        .transition = "trash",
    });

    const destroyed = try ctx.call(record.Transition, .{
        .id = in.id,
        .transition = "destroy",
    });

    return .{
        .status = if (destroyed.pending) "trashed" else destroyed.status,
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = operations,
    .permissions = &.{
        .{
            .key = "records.write",
            .records = &.{"note"},
            .publish = true,
            .reason = "Puts new prices live",
        },
        .{
            .key = "records.destroy",
            .records = &.{"note"},
            .reason = "Withdraws a price for good",
        },
    },
});
