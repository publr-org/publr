const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/ledger.zig");
const engine = @import("ledger/engine.zig");
const reads = @import("ledger/reads.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const HolderKind = public.HolderKind;
pub const StepAction = public.StepAction;
pub const Step = public.Step;
pub const Done = public.Done;

pub const Open = struct {
    pub const shape = public.Open;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return engine.open(ctx, in);
    }
};

pub const Transfer = Moving(public.Transfer, .transfer);
pub const Hold = Moving(public.Hold, .hold);

fn Moving(comptime Shape: type, comptime action: StepAction) type {
    return struct {
        pub const shape = Shape;
        pub const name = shape.name;
        pub const plugins_only = shape.plugins_only;
        pub const description = shape.description;
        pub const details = shape.details;
        pub const kind = shape.kind;
        pub const In = shape.In;
        pub const Out = shape.Out;
        pub const example = shape.example;
        pub const example_out = shape.example_out;
        pub const field_docs = shape.field_docs;
        pub const output_docs = shape.output_docs;

        pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
            var step = in;

            step.action = action;

            const done = try engine.post(ctx, &.{step});

            std.debug.assert(done.len == 1);

            return done[0];
        }
    };
}

pub const PostHold = struct {
    pub const shape = public.PostHold;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const done = try engine.post(ctx, &.{.{
            .action = .post_hold,
            .hold = in.hold,
            .amount = in.amount,
        }});

        return done[0];
    }
};

pub const VoidHold = struct {
    pub const shape = public.VoidHold;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        const done = try engine.post(ctx, &.{.{
            .action = .void_hold,
            .hold = in.hold,
        }});

        return done[0];
    }
};

pub const Chain = struct {
    pub const shape = public.Chain;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return .{
            .done = try engine.post(ctx, in.steps),
        };
    }
};

pub const Reverse = struct {
    pub const shape = public.Reverse;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return engine.reverse(ctx, in);
    }
};

pub const Convert = struct {
    pub const shape = public.Convert;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        return engine.convert(ctx, in);
    }
};

pub const Close = Closing(public.Close, true);
pub const Reopen = Closing(public.Reopen, false);

fn Closing(comptime Shape: type, comptime closed: bool) type {
    return struct {
        pub const shape = Shape;
        pub const name = shape.name;
        pub const plugins_only = shape.plugins_only;
        pub const description = shape.description;
        pub const details = shape.details;
        pub const kind = shape.kind;
        pub const In = shape.In;
        pub const Out = shape.Out;
        pub const example = shape.example;
        pub const example_out = shape.example_out;
        pub const field_docs = shape.field_docs;
        pub const output_docs = shape.output_docs;

        pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
            try engine.set_closed(ctx, in.account, closed);

            return .{
                .closed = closed,
            };
        }
    };
}

pub const Balance = reads.Balance;
pub const BalanceOut = reads.Balance.Out;
pub const History = reads.History;
pub const HistoryOut = reads.History.Out;
pub const Find = reads.Find;
pub const Totals = reads.Totals;
pub const Sum = reads.Sum;
pub const Line = reads.Line;
pub const Get = reads.Get;
pub const Shown = reads.Shown;
pub const Accounts = reads.Accounts;
pub const AccountsOut = reads.Accounts.Out;
pub const Account = reads.Account;
pub const Check = reads.Check;
pub const AccountView = reads.AccountView;
pub const UnitLine = @import("ledger/accounts.zig").UnitLine;

/// A hold not settled by its expiry is voided by core, natively, as its own queued job.
pub const expire_job = engine.expire_job;
pub const Expired = engine.Expired;

pub const operations = [_]type{
    Open,   Transfer, Hold,    PostHold, VoidHold, Chain, Reverse,  Convert, Close,
    Reopen, Balance,  History, Find,     Totals,   Get,   Accounts, Account, Check,
};
