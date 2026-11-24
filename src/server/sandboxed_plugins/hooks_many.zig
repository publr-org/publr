//! Installed `before` and `after` hooks over many inputs at once, as a write over many
//! records fires them: each plugin's hook is entered once with every input still going
//! (`batched.zig`), never once an input. Each input is still heard on its own: a hook
//! refuses one and the rest go on.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const invoke_module = @import("invoke.zig");
const interface = @import("interface.zig");
const hooks = @import("hooks.zig");
const batched = @import("batched.zig");

const Passed = sdk.sandboxed_plugins.Passed;
const Outcome = sdk.sandboxed_plugins.Outcome;
const Stage = sdk.sandboxed_plugins.Stage;

/// Every `before` hook on `name` over `inputs`, in turn, each handed what the one before
/// left: `outcomes` takes each input as the last hook left it, or how it was refused.
pub fn before(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    inputs: []const Passed,
    outcomes: []Outcome,
) sdk.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(inputs.len == outcomes.len);

    for (inputs, outcomes) |input, *outcome| {
        outcome.* = .{
            .passed = input,
        };
    }

    try each(context, ctx, .before, name, null, outcomes);
}

/// Every `after` hook on `name` over `inputs`, each with what the write made of it
/// (`outputs`): `outcomes` takes how each was refused, if it was.
pub fn after(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    name: []const u8,
    inputs: []const Passed,
    outputs: []const Passed,
    outcomes: []Outcome,
) sdk.Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(inputs.len == outputs.len and inputs.len == outcomes.len);

    for (inputs, outcomes) |input, *outcome| {
        outcome.* = .{
            .passed = input,
        };
    }

    try each(context, ctx, .after, name, outputs, outcomes);
}

/// Each hook of `stage` on `name`, entered once for every part of the inputs still going.
fn each(
    context: *anyopaque,
    ctx: *sdk.Ctx,
    stage: Stage,
    name: []const u8,
    outputs: ?[]const Passed,
    outcomes: []Outcome,
) sdk.Error!void {
    const host = interface.host_of(context);

    std.debug.assert(stage == .before or stage == .after);
    std.debug.assert(outputs == null or outputs.?.len == outcomes.len);

    for (hooks.targets_of(host, stage, name)) |target| {
        const loaded = &host.loaded.items[target.sandboxed_plugin];
        var access = try interface.access_of(loaded, ctx);
        var start: u32 = 0;

        while (start < outcomes.len) {
            var parts: [batched.items_max]invoke_module.Parts = undefined;
            var places: [batched.items_max]u32 = undefined;
            var ended: [batched.items_max]Outcome = undefined;
            var count: u32 = 0;

            while (start < outcomes.len and count < batched.items_max) : (start += 1) {
                const heard = outcomes[start].failed == null and
                    hooks.hears(loaded, ctx, target, name, outcomes[start].passed);

                if (!heard) {
                    continue;
                }

                parts[count] = .{
                    .in = outcomes[start].passed,
                    .out = if (outputs) |made| made[start] else null,
                };
                places[count] = start;
                count += 1;
            }

            if (count == 0) {
                break;
            }

            try invoke_module.invoke_many(
                loaded,
                ctx,
                &access,
                target.entry,
                parts[0..count],
                ended[0..count],
            );

            for (places[0..count], ended[0..count]) |place, one| {
                // An `after` hook answers nothing the next reads: the input goes on as it was.
                if (stage == .before or one.failed != null) {
                    outcomes[place] = one;
                }
            }
        }
    }
}
