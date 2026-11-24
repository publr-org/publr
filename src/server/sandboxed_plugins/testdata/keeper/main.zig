//! Keeps a number in its memory.
//!
//! The plugin the sandbox's instances are tested with, only ever installed: `keeper remember`
//! leaves a number in the module's memory and answers the one it found there, so a test sees
//! whether two calls ran on one instance. `keeper crash` traps, `keeper spin` works for a
//! while, and `relay`, `stumble` and `spin_nested` call those from inside a call of its own.
//! `keeper weigh` passes a load through the plugin's modifier, which works as long as the
//! load says.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "keeper",
    .version = "0.1.0",
};

const operations = [_]type{ Remember, Relay, Crash, Stumble, Spin, SpinNested, Weigh };

// What a call left in the module's memory: the one thing here that outlasts a call.
var kept: u32 = 0;

pub const RememberIn = struct {
    /// The number to keep
    value: u32,
};

pub const RememberOut = struct {
    /// The number that was kept before
    before: u32,
};

/// Keep a number, and answer the one kept before
///
/// Example:
///   in: { "value": 5 }
///   out: { "before": 0 }
pub const Remember = publr.operation.define(RememberIn, RememberOut, .{
    .name = "remember",
    .kind = .read,
    .run = remember,
});

fn remember(ctx: *publr.Ctx, in: RememberIn) publr.Error!RememberOut {
    std.debug.assert(ctx.now().ms >= 0);

    const before = kept;

    kept = in.value;

    return .{
        .before = before,
    };
}

pub const RelayOut = struct {
    /// The number that was kept before
    before: u32,
    /// The number its own `remember` found, called from inside this call
    inner: u32,
};

/// Keep a number, then call `remember` from inside the call
///
/// Example:
///   in: { "value": 5 }
///   out: { "before": 0, "inner": 5 }
pub const Relay = publr.operation.define(RememberIn, RelayOut, .{
    .name = "relay",
    .kind = .read,
    .run = relay,
});

fn relay(ctx: *publr.Ctx, in: RememberIn) publr.Error!RelayOut {
    std.debug.assert(ctx.now().ms >= 0);

    const before = kept;

    kept = in.value;

    const inner = try ctx.call(Remember, .{
        .value = in.value + 1,
    });

    return .{
        .before = before,
        .inner = inner.before,
    };
}

pub const Nothing = struct {};

/// Stop on a trap
///
/// Example:
///   in: {}
///   out: {}
pub const Crash = publr.operation.define(Nothing, Nothing, .{
    .name = "crash",
    .kind = .read,
    .run = crash,
});

fn crash(ctx: *publr.Ctx, _: Nothing) publr.Error!Nothing {
    std.debug.assert(ctx.now().ms >= 0);

    kept = 99;

    if (ctx.now().ms >= 0) {
        @trap();
    }

    return .{};
}

pub const StumbleOut = struct {
    /// Whether its own `crash`, called from inside this call, ended in an error
    crashed: bool,
    /// Whether its own `remember`, called after that, was refused
    refused: bool,
};

/// Call `crash` from inside the call, then `remember`
///
/// Example:
///   in: {}
///   out: { "crashed": true, "refused": true }
pub const Stumble = publr.operation.define(Nothing, StumbleOut, .{
    .name = "stumble",
    .kind = .read,
    .run = stumble,
});

fn stumble(ctx: *publr.Ctx, _: Nothing) publr.Error!StumbleOut {
    std.debug.assert(ctx.now().ms >= 0);

    const crashed = if (ctx.call(Crash, .{})) |_| false else |_| true;
    const refused = if (ctx.call(Remember, .{
        .value = 1,
    })) |_| false else |_| true;

    return .{
        .crashed = crashed,
        .refused = refused,
    };
}

pub const SpinIn = struct {
    /// How many rounds to work
    rounds: u32,
    /// Which turn this is, of a caller that asks many times
    turn: u32 = 0,
};

pub const SpinOut = struct {
    /// What the rounds added up to
    sum: u32,
};

/// Work for some rounds
///
/// Example:
///   in: { "rounds": 10 }
///   out: { "sum": 1395 }
pub const Spin = publr.operation.define(SpinIn, SpinOut, .{
    .name = "spin",
    .kind = .read,
    .run = spin,
});

fn spin(ctx: *publr.Ctx, in: SpinIn) publr.Error!SpinOut {
    std.debug.assert(ctx.now().ms >= 0);

    var total: u32 = 0;
    var index: u32 = 0;

    while (index < in.rounds) : (index += 1) {
        total +%= index *% 31;
        asm volatile ("");
    }

    return .{
        .sum = total,
    };
}

/// Call `spin` as many times as `turn` says, from inside the call
///
/// Example:
///   in: { "rounds": 10, "turn": 2 }
///   out: { "sum": 2790 }
pub const SpinNested = publr.operation.define(SpinIn, SpinOut, .{
    .name = "spin_nested",
    .kind = .read,
    .run = spin_nested,
});

fn spin_nested(ctx: *publr.Ctx, in: SpinIn) publr.Error!SpinOut {
    std.debug.assert(in.turn <= 64);

    var total: u32 = 0;
    var turn: u32 = 0;

    while (turn < in.turn) : (turn += 1) {
        const inner = try ctx.call(Spin, .{
            .rounds = in.rounds,
            .turn = turn + 1,
        });

        total +%= inner.sum;
    }

    return .{
        .sum = total,
    };
}

pub const Load = struct {
    /// How many rounds weighing it takes
    rounds: u32,
    /// What the rounds added up to
    weight: u32 = 0,
};

/// Weigh a load through the plugin's own modifier
///
/// Example:
///   in: { "rounds": 10 }
///   out: { "rounds": 10, "weight": 1395 }
pub const Weigh = publr.operation.define(Load, Load, .{
    .name = "weigh",
    .kind = .read,
    .run = weigh,
});

fn weigh(ctx: *publr.Ctx, in: Load) publr.Error!Load {
    std.debug.assert(in.weight == 0);

    return ctx.mod("keeper.load", in);
}

/// Works for as many rounds as the load says: a load of very many runs out of the budget.
fn weighed(ctx: *publr.Ctx, load: *Load) publr.Error!void {
    std.debug.assert(ctx.now().ms >= 0);

    var total: u32 = 0;
    var index: u32 = 0;

    while (index < load.rounds) : (index += 1) {
        total +%= index *% 31;
        asm volatile ("");
    }

    load.weight = total;
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = operations,
    .hooks = .{
        publr.modify("keeper.load", weighed),
    },
});
