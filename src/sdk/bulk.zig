//! An operation's hooks (`before` and `after`, compiled in or installed) run over
//! many inputs at once, as a write over many records runs them: each input is still heard
//! on its own, so a hook refuses one input and the rest go on, but the write itself is done
//! once for all of them.
const std = @import("std");
const sdk = @import("../sdk.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

/// Why each input was refused, by position; null for one that goes on.
pub const Refusals = []?[]const u8;

pub const changed_by_hook = "A hook changes this move; make it on its own";

pub fn Bulk(comptime SDK: type, comptime registry: sdk.Registry) type {
    return struct {
        /// Whether any hook is on `Operation`: with none, a bulk write runs no hook at all.
        pub fn hooked(ctx: *const Ctx, comptime Operation: type) bool {
            std.debug.assert(Operation.name.len > 0);
            std.debug.assert(registry.middleware.len <= sdk.middleware.middleware_max);

            inline for (registry.middleware) |Middleware| {
                const applies = comptime sdk.middleware.applies(Middleware, Operation);

                if (applies) {
                    return true;
                }
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

            inline for (registry.middleware) |Middleware| {
                const applies = comptime sdk.middleware.applies(Middleware, Operation) and
                    Middleware.stage == .before;

                if (applies) {
                    for (inputs, refused) |input, *reason| {
                        if (reason.* == null) {
                            reason.* = try before_one(ctx, Middleware, Operation, input);
                        }
                    }
                }
            }

            const sandboxed = ctx.sandboxed_plugins orelse return;

            if (!sandboxed.hooked(.before, Operation.name)) {
                return;
            }

            for (inputs, refused) |input, *reason| {
                if (reason.* == null) {
                    reason.* = try installed_before(ctx, sandboxed, Operation, input);
                }
            }
        }

        fn before_one(
            ctx: *Ctx,
            comptime Middleware: type,
            comptime Operation: type,
            input: Operation.In,
        ) Error!?[]const u8 {
            std.debug.assert(ctx.parent != null);
            comptime std.debug.assert(Middleware.stage == .before);

            var changed = input;

            SDK.invoke_hook(ctx, Middleware, .{&changed}) catch |err| {
                return try reason_of(ctx, err);
            };

            return try unchanged(ctx, input, changed);
        }

        fn installed_before(
            ctx: *Ctx,
            sandboxed: *const sdk.sandboxed_plugins.SandboxedPlugins,
            comptime Operation: type,
            input: Operation.In,
        ) Error!?[]const u8 {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(Operation.name.len > 0);

            const changed = SDK.runtime_before(ctx, sandboxed, Operation, input) catch |err| {
                return try reason_of(ctx, err);
            };

            return try unchanged(ctx, input, changed);
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

            inline for (registry.middleware) |Middleware| {
                const applies = comptime sdk.middleware.applies(Middleware, Operation) and
                    Middleware.stage == .after;

                if (applies) {
                    for (inputs, outputs, refused) |input, output, *reason| {
                        if (reason.* == null) {
                            var given = input;
                            var made = output;

                            SDK.invoke_hook(ctx, Middleware, .{ &given, &made }) catch |err| {
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

            for (inputs, outputs, refused) |input, output, *reason| {
                if (reason.* == null) {
                    SDK.runtime_after(ctx, sandboxed, Operation, input, output) catch |err| {
                        reason.* = try reason_of(ctx, err);
                    };
                }
            }
        }
    };
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
