//! An operation's hooks (`before` and `after`, compiled in or installed) run over
//! many inputs at once, as a write over many records runs them: each input is still heard
//! on its own, so a hook refuses one input and the rest go on, but the write itself is done
//! once for all of them.
const std = @import("std");
const sdk = @import("../sdk.zig");
const json = @import("../lib/json.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// Why each input was refused, by position; null for one that goes on.
pub const Refusals = []?[]const u8;

pub const changed_by_hook = "A hook changes this move; make it on its own";

pub fn Bulk(comptime SDK: type, comptime registry: sdk.Registry) type {
    return struct {
        const tables = @import("registry_tables.zig").Tables(registry);

        /// Whether any hook is on `Operation`: with none, a bulk write runs no hook at all.
        pub fn hooked(ctx: *const Ctx, comptime Operation: type) bool {
            std.debug.assert(Operation.name.len > 0);
            std.debug.assert(registry.hooks.len <= sdk.hooks.hooks_max);

            if (comptime tables.hooks_on(Operation.name).len > 0) {
                return true;
            }

            const sandboxed = ctx.sandboxed_plugins orelse return false;

            return sandboxed.hooked(.before, Operation.name) or
                sandboxed.hooked(.after, Operation.name);
        }

        /// The `before` hooks over the inputs not yet refused. An input a hook changes is
        /// refused too: a bulk write does the same to every input.
        pub fn before_each(
            ctx: *Ctx,
            comptime Operation: type,
            inputs: []const Operation.In,
            refused: Refusals,
        ) Error!void {
            std.debug.assert(inputs.len == refused.len);
            std.debug.assert(ctx.parent != null);

            inline for (comptime tables.hooks_on(Operation.name)) |index| {
                const applies = comptime registry.hooks[index].stage == .before;

                if (applies) {
                    for (inputs, refused) |input, *reason| {
                        if (reason.* == null) {
                            reason.* = try before_one(ctx, index, Operation, input);
                        }
                    }
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return;

            if (!sandboxed.hooked(.before, Operation.name)) {
                return;
            }

            try installed_before(ctx, sandboxed, Operation, inputs, refused);
        }

        fn before_one(
            ctx: *Ctx,
            comptime index: u32,
            comptime Operation: type,
            input: Operation.In,
        ) Error!?[]const u8 {
            std.debug.assert(ctx.parent != null);
            comptime std.debug.assert(registry.hooks[index].stage == .before);

            var changed = input;

            SDK.invoke_hook(ctx, index, .{&changed}) catch |err| {
                return try reason_of(ctx, err);
            };

            return try unchanged(ctx, input, changed);
        }

        /// The `before` or `after` hooks on the event `name` over many payloads at once (a
        /// null is a record that emits another event, or none): compiled-in hooks hear each
        /// on its own, then each installed plugin's hook is entered once for all still going.
        /// One a hook refuses is refused; the rest go on.
        pub fn on_each(
            ctx: *Ctx,
            comptime stage: sdk.hooks.Stage,
            name: []const u8,
            payloads: []const ?[]const u8,
            refused: Refusals,
        ) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(payloads.len == refused.len);

            const blocked = ctx.arena.alloc(?[]const u8, refused.len) catch {
                return error.OutOfMemory;
            };

            for (payloads, refused, blocked) |payload, *reason, *skip| {
                const heard = payload orelse {
                    skip.* = "";
                    continue;
                };

                if (reason.* == null) {
                    SDK.hooks_on_compiled(ctx, stage, name, heard, true) catch |err| {
                        reason.* = try reason_of(ctx, err);
                    };
                }

                skip.* = reason.*;
            }

            const sandboxed = ctx.sandboxed_plugins orelse return;
            const Stage = sdk.sandboxed_plugins.Stage;
            const hook_stage: Stage = if (stage == .before) .before else .after;

            if (!sandboxed.hooked(hook_stage, name)) {
                return;
            }

            const going = try Going.heard(ctx, payloads, blocked);

            if (going.places.len == 0) {
                return;
            }

            if (stage == .before) {
                try sandboxed.before_many(ctx, name, going.inputs, going.outcomes);
            } else {
                try sandboxed.after_many(ctx, name, going.inputs, going.outputs, going.outcomes);
            }

            for (going.places, going.outcomes) |place, outcome| {
                if (outcome.failed) |err| {
                    refused[place] = try said(err, outcome.message);
                }
            }
        }

        /// Every installed `before` hook over the inputs still going, each plugin's hook
        /// entered once for all of them.
        fn installed_before(
            ctx: *Ctx,
            sandboxed: *const sdk.sandboxed_plugins.SandboxedPlugins,
            comptime Operation: type,
            inputs: []const Operation.In,
            refused: Refusals,
        ) Error!void {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(inputs.len == refused.len);

            const going = try Going.of(ctx, inputs, null, refused);

            if (going.places.len == 0) {
                return;
            }

            try sandboxed.before_many(ctx, Operation.name, going.inputs, going.outcomes);

            for (going.places, going.outcomes) |place, outcome| {
                if (outcome.failed) |err| {
                    refused[place] = try said(err, outcome.message);
                    continue;
                }

                const text = try sandboxed.json_of(ctx.arena, outcome.passed, .answer);
                const changed = json.parse(Operation.In, ctx.arena, text, .{
                    .allocate = .alloc_always,
                }) catch {
                    refused[place] = @errorName(error.Invalid);
                    continue;
                };

                refused[place] = try unchanged(ctx, inputs[place], changed);
            }
        }

        /// Every installed `after` hook over the inputs written, each plugin's hook entered
        /// once for all of them.
        fn installed_after(
            ctx: *Ctx,
            sandboxed: *const sdk.sandboxed_plugins.SandboxedPlugins,
            comptime Operation: type,
            inputs: []const Operation.In,
            outputs: []const Operation.Out,
            refused: Refusals,
        ) Error!void {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(inputs.len == outputs.len);

            const going = try Going.of(ctx, inputs, outputs, refused);

            if (going.places.len == 0) {
                return;
            }

            try sandboxed.after_many(
                ctx,
                Operation.name,
                going.inputs,
                going.outputs,
                going.outcomes,
            );

            for (going.places, going.outcomes) |place, outcome| {
                if (outcome.failed) |err| {
                    refused[place] = try said(err, outcome.message);
                }
            }
        }

        /// The `after` hooks over the inputs written, each with what the write made of it.
        pub fn after_each(
            ctx: *Ctx,
            comptime Operation: type,
            inputs: []const Operation.In,
            outputs: []const Operation.Out,
            refused: Refusals,
        ) Error!void {
            std.debug.assert(inputs.len == outputs.len);
            std.debug.assert(inputs.len == refused.len);

            inline for (comptime tables.hooks_on(Operation.name)) |index| {
                const applies = comptime registry.hooks[index].stage == .after;

                if (applies) {
                    for (inputs, outputs, refused) |input, output, *reason| {
                        if (reason.* == null) {
                            var given = input;
                            var made = output;

                            SDK.invoke_hook(ctx, index, .{ &given, &made }) catch |err| {
                                reason.* = try reason_of(ctx, err);
                            };
                        }
                    }
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return;

            if (!sandboxed.hooked(.after, Operation.name)) {
                return;
            }

            // A hook adding fields to a list's rows answers each on its own.
            if (comptime @hasField(Operation.Out, "extended")) {
                for (inputs, outputs, refused) |input, output, *reason| {
                    if (reason.* == null) {
                        SDK.runtime_after(ctx, sandboxed, Operation, input, output) catch |err| {
                            reason.* = try reason_of(ctx, err);
                        };
                    }
                }

                return;
            }

            try installed_after(ctx, sandboxed, Operation, inputs, outputs, refused);
        }
    };
}

const Passed = sdk.sandboxed_plugins.Passed;

/// The inputs of a bulk write no hook has refused yet, as installed hooks take them.
const Going = struct {
    /// Where each stands among all the inputs.
    places: []const u32,
    inputs: []const Passed,
    outputs: []const Passed,
    outcomes: []sdk.sandboxed_plugins.Outcome,

    fn of(ctx: *Ctx, inputs: anytype, outputs: anytype, refused: Refusals) Error!Going {
        std.debug.assert(inputs.len == refused.len);

        var count: u32 = 0;

        for (refused) |reason| {
            count += @intFromBool(reason == null);
        }

        const arena = ctx.arena;
        const places = arena.alloc(u32, count) catch return error.OutOfMemory;
        const given = arena.alloc(Passed, count) catch return error.OutOfMemory;
        const made = arena.alloc(Passed, count) catch return error.OutOfMemory;
        const outcomes = arena.alloc(sdk.sandboxed_plugins.Outcome, count) catch {
            return error.OutOfMemory;
        };
        var next: u32 = 0;

        for (refused, 0..) |reason, place| {
            if (reason != null) {
                continue;
            }

            places[next] = @intCast(place);
            given[next] = .{
                .json = try sdk.stringify(arena, inputs[place]),
            };
            made[next] = .{
                .json = if (@TypeOf(outputs) == @TypeOf(null))
                    "{}"
                else
                    try sdk.stringify(arena, outputs[place]),
            };
            next += 1;
        }

        std.debug.assert(next == count);

        return .{
            .places = places,
            .inputs = given,
            .outputs = made,
            .outcomes = outcomes,
        };
    }
    /// The payloads of an event still going (`blocked` null), as installed hooks take them.
    fn heard(ctx: *Ctx, payloads: []const ?[]const u8, blocked: []const ?[]const u8) Error!Going {
        std.debug.assert(payloads.len == blocked.len);

        var count: u32 = 0;

        for (blocked) |reason| {
            count += @intFromBool(reason == null);
        }

        const arena = ctx.arena;
        const places = arena.alloc(u32, count) catch return error.OutOfMemory;
        const given = arena.alloc(Passed, count) catch return error.OutOfMemory;
        const made = arena.alloc(Passed, count) catch return error.OutOfMemory;
        const outcomes = arena.alloc(sdk.sandboxed_plugins.Outcome, count) catch {
            return error.OutOfMemory;
        };
        var next: u32 = 0;

        for (payloads, blocked, 0..) |payload, reason, place| {
            if (reason != null) {
                continue;
            }

            places[next] = @intCast(place);
            given[next] = .{
                .json = payload.?,
            };
            made[next] = .{
                .json = "{}",
            };
            next += 1;
        }

        std.debug.assert(next == count);

        return .{
            .places = places,
            .inputs = given,
            .outputs = made,
            .outcomes = outcomes,
        };
    }
};

/// A hook's refusal of one input of a batch in words: its own message, else the error's
/// name. Running out of memory is never a refusal: the whole write fails.
fn said(err: Error, message: []const u8) Error![]const u8 {
    std.debug.assert(@errorName(err).len > 0);

    if (err == error.OutOfMemory) {
        return err;
    }

    return if (message.len > 0) message else @errorName(err);
}

/// A hook's refusal in words: its own message, else the error's name. Running out of
/// memory is never a refusal: the whole write fails.
pub fn reason_of(ctx: *Ctx, err: Error) Error![]const u8 {
    std.debug.assert(@errorName(err).len > 0);

    if (err == error.OutOfMemory) {
        return err;
    }

    const failure = ctx.failure;

    ctx.failure = null;

    return if (failure) |own| own.message else @errorName(err);
}

fn unchanged(ctx: *Ctx, input: anytype, changed: @TypeOf(input)) Error!?[]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const before = try sdk.stringify(ctx.arena, input);
    const after = try sdk.stringify(ctx.arena, changed);

    std.debug.assert(before.len > 0);

    return if (std.mem.eql(u8, before, after)) null else changed_by_hook;
}
