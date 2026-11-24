//! Keeps a till's moves: how many of an item went in or out.
//!
//! The plugin internal records' field rules are tested with: each move is kept under the
//! id its caller gave (unique: the same id twice is a conflict), its count within bounds,
//! its note no longer than 20, the messaging provider that told of it named by a provider
//! field, and the move's own rule that a refund names why. Its regulars are a user type
//! visitors sign up to, whose accounts it manages with `users.own` and nobody else's.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "till",
    .version = "0.1.0",
};

/// A move
///
/// Money in or out of the till.
pub const Move = struct {
    /// Id
    ///
    /// The caller's own: the same move sent twice is kept once.
    key: []const u8,
    /// Count
    count: i64,
    /// Note
    note: []const u8 = "",
    /// Refund
    refund: bool = false,
    /// Told by
    told_by: ?publr.ProviderRef(publr.messaging.contract) = null,
    /// Lines
    ///
    /// What moved, at most three.
    lines: []const MoveLine = &.{},
    /// Count again at
    ///
    /// When the till is counted again after this move.
    recount_at: ?publr.Time = null,
};

/// A line of a move
pub const MoveLine = struct {
    /// Item
    sku: []const u8,
};

/// A refund says why.
fn refund_says_why(move: Move, problems: *publr.Problems(Move)) void {
    std.debug.assert(move.key.len > 0);

    if (move.refund and move.note.len == 0) {
        problems.add(.note, "A refund says why.");
    }
}

pub const Moves = publr.record.define(Move, .{
    .name = "till.move",
    .internal = true,
    .validate = refund_says_why,
    .fields = .{
        .key = .{
            .validation = .{
                .unique = true,
            },
        },
        .count = .{
            .validation = .{
                .min = -100_000,
                .max = 100_000,
            },
        },
        .note = .{
            .validation = .{
                .max_len = 20,
            },
        },
        .lines = .{
            .validation = .{
                .items_max = 3,
            },
        },
    },
});

/// A till's regulars: visitors who sign up on the `www` app.
const user_types = [_]publr.plugin.UserType{.{
    .name = "till_regular",
    .label = "Regular",
    .apps = &.{"www"},
    .sign_up = true,
    .roles = &.{"till_regular"},
}};

/// What a regular holds: nothing of the admin's, only what visitors call.
const roles = [_]publr.plugin.Role{.{
    .name = "till_regular",
    .label = "Regular",
    .description = "A regular of the till",
}};

pub const AddIn = struct {
    /// Their email
    email: []const u8,
    /// Staff instead of a regular, which the till may not make
    staff: bool = false,
    /// The roles the account holds, which the till may not make staff
    roles: []const []const u8 = &.{"till_regular"},
};

pub const AddOut = struct {
    /// The account
    ///
    /// Why: an account is no record a `Ref` points at.
    user_id: []const u8,
};

/// Adds a regular, or tries to add staff.
///
/// Example:
///   in: { "email": "ada@example.com" }
///   out: { "user_id": "9b1e7c3d5a2f4e6b8d0c1a3f" }
pub const Add = publr.operation.define(AddIn, AddOut, .{
    .name = "add",
    .kind = .write,
    .run = add,
});

fn add(ctx: *publr.Ctx, in: AddIn) publr.Error!AddOut {
    std.debug.assert(in.email.len > 0);

    const made = try ctx.call(publr.operations.user.Create, .{
        .email = in.email,
        .display_name = "Regular",
        .password = "correct horse battery",
        .roles = in.roles,
        .user_type = if (in.staff) "" else "till_regular",
    });

    return .{
        .user_id = made.user_id,
    };
}

fn recount(ctx: *publr.QueueCtx, move: Moves.Held) publr.Error!void {
    std.debug.assert(move.id.len > 0);
    std.debug.assert(ctx.now().ms >= 0);

    ctx.log(.info, "job recount: after {s}", .{move.value.key});
}

/// An hour after a move's recount time: queued by every write to the move.
pub const Recount = publr.job.define(Moves, .{
    .name = "recount",
    .run = recount,
    .due = .{
        .field = .recount_at,
        .after = .hour,
    },
});

pub const JoinIn = struct {
    /// Whose account
    email: []const u8,
    /// Take the type instead of giving it
    leave: bool = false,
    /// Rename the account too, which is not the till's to do on staff
    rename: bool = false,
};

pub const JoinOut = struct {
    /// The account's types now
    user_types: []const []const u8,
};

/// Gives an account the regulars' type, or takes it.
///
/// Example:
///   in: { "email": "ada@example.com" }
///   out: { "user_types": ["till_regular"] }
pub const Join = publr.operation.define(JoinIn, JoinOut, .{
    .name = "join",
    .kind = .write,
    .run = join,
});

fn join(ctx: *publr.Ctx, in: JoinIn) publr.Error!JoinOut {
    std.debug.assert(in.email.len > 0);

    if (in.rename) {
        _ = try ctx.call(publr.operations.user.Update, .{
            .user = in.email,
            .display_name = "Renamed",
            .roles = &.{"editor"},
        });
    }

    const typed: publr.operations.user.types.TypeIn = .{
        .user = in.email,
        .user_type = "till_regular",
    };
    const changed = if (in.leave)
        try ctx.call(publr.operations.user.RemoveType, typed)
    else
        try ctx.call(publr.operations.user.AddType, typed);

    return .{
        .user_types = changed.user_types,
    };
}

pub const FollowIn = struct {
    /// The path asked for
    path: []const u8,
    /// What follows the prefix
    rest: []const u8,
};

pub const FollowOut = struct {
    /// Where the visitor goes
    to: []const u8,
};

/// Sends a visitor arriving under `/till/` to the till's page for what follows
///
/// Example:
///   in: { "path": "/till/ada", "rest": "ada" }
///   out: { "to": "/regulars/ada" }
pub const Follow = publr.operation.define(FollowIn, FollowOut, .{
    .name = "follow",
    .kind = .read,
    .run = follow,
});

fn follow(ctx: *publr.Ctx, in: FollowIn) publr.Error!FollowOut {
    std.debug.assert(in.path.len > 0);

    return .{
        .to = try ctx.print("/regulars/{s}", .{in.rest}),
    };
}

pub const SeenIn = struct {};

pub const SeenOut = struct {
    /// The referral the visitor first brought; empty when none
    ref: []const u8,
};

/// Which referral the visitor first came with
///
/// Example:
///   in: {}
///   out: { "ref": "ada" }
pub const Seen = publr.operation.define(SeenIn, SeenOut, .{
    .name = "seen",
    .kind = .read,
    .untrusted_callers = true,
    .run = seen,
});

fn seen(ctx: *publr.Ctx, _: SeenIn) publr.Error!SeenOut {
    std.debug.assert(ctx.now().ms >= 0);

    const read = try ctx.call(publr.operations.request.Read, .{});

    for (read.first.values) |value| {
        if (std.mem.eql(u8, value.name, "ref")) {
            return .{
                .ref = value.value,
            };
        }
    }

    return .{
        .ref = "",
    };
}

const permissions = .{
    .{
        .key = "users.own",
        .reason = "Makes accounts for the till's regulars, and makes anyone one",
    },
    .{
        .key = "request.read",
        .reason = "Knows which regular sent a visitor",
    },
    .{
        .key = "request.redirect",
        .reason = "Answers links to a regular's page",
    },
};

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Moves},
    .user_types = &user_types,
    .roles = &roles,
    .operations = &.{ Add, Join, Follow, Seen },
    .jobs = &.{Recount},
    .request = .{
        .query = .{"ref"},
        .redirects = .{.{
            .prefix = "/till/",
            .operation = "follow",
        }},
    },
    .permissions = permissions,
});
