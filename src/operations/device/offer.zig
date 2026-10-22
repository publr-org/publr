//! A sign-in offered to a person's own computer: approved as it is made, by the person signed
//! in to the admin, and collected once with `device claim` by whoever holds its code within
//! ten minutes. What the Overview's agent command carries, so setting up a computer is one
//! command with nothing to approve.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const model = @import("../../model/device.zig");
const device = @import("../device.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

/// What the device is called until its CLI names it.
pub const offered_name = "A computer set up from the Overview";

pub const Offer = struct {
    /// Its example runs as a signed-in account (`--as`).
    pub const example_signed_in = true;
    pub const name = "device.offer";
    /// Anyone signed in offers their own sign-in: the token holds their roles, no more.
    pub const open = true;
    pub const description = "Offer this account's sign-in to a computer, as a one-time code";
    pub const details =
        \\Any signed-in person (not a device), for their own account. Makes a device request
        \\already approved for the caller's account under `scope`, and answers its code: whoever
        \\holds it takes the token once with `device claim --device_code <code>`, within ten
        \\minutes. Treat the code like a password until it is used or lapses.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        scope: []const u8 = "write",
    };
    pub const Out = struct {
        code: []const u8,
        expires_at: i64,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .code = "k7q2xm4pw9tz3hbd",
        .expires_at = 1792232000000,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .scope = "What the computer may do: `read`, `drafts` or `write` (the default)",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .code = "The one-time code, for `device claim`",
        .expires_at = "When it lapses, Unix milliseconds",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const user_id = switch (ctx.caller) {
            .user => |user| user.id,
            else => return error.Denied,
        };

        if (model.Scope.parse(in.scope) == null) {
            return error.Invalid;
        }

        _ = try store.device_requests.cleanup(ctx.db, ctx.now_ms);

        var random: [model.offer_code_len]u8 = undefined;
        ctx.io.random(&random);

        const code = model.offer_code(random);
        const expires_at = ctx.now_ms + model.request_lifetime_ms;
        const user_code = try device.insert(ctx, .{
            .code_hash = device.hash_of(&code),
            .name = offered_name,
            .scope = in.scope,
            .expires_at = expires_at,
        });
        const decided = try store.device_requests.decide(ctx.db, .{
            .state = "approved",
            .scope = in.scope,
            .user_id = user_id,
            .user_code = user_code,
        }, ctx.now_ms);

        std.debug.assert(decided);

        return .{
            .code = try ctx.arena.dupe(u8, &code),
            .expires_at = expires_at,
        };
    }
};
