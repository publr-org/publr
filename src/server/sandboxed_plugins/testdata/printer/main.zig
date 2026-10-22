//! Prints a label, for the tests of `on` hooks that fail.
//!
//! `print` records a label and how many times the printer is to fail it; its `on` hook
//! "sends" it, failing that many tries (counted in an internal record), then printing. A
//! second hook files a copy and never fails, so a failing send never runs it again.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "printer",
    .version = "0.1.0",
};

/// A try at printing a label.
pub const Try = struct {
    /// The label tried
    label: []const u8,
};

pub const Tries = publr.record.define(Try, .{
    .name = "printer.try",
    .internal = true,
    .indexed = &.{.label},
    .scope = .app,
});

/// How many tries a label has had.
const tried_of = publr.query.prepare(
    \\count(*[_type == "printer.try" && label == $label])
, .{});

pub const PrintIn = struct {
    /// What the label says
    label: []const u8,
    /// How many tries fail before it prints; more than eight never prints
    fails: u32 = 0,
};

pub const PrintOut = struct {
    /// What the label says
    label: []const u8,
    /// How many tries fail before it prints
    fails: u32,
};

/// Queues a label for the printer.
///
/// Example:
///   in: { "label": "Box 4", "fails": 2 }
///   out: { "label": "Box 4", "fails": 2 }
pub const Print = publr.operation.define(PrintIn, PrintOut, .{
    .name = "print",
    .kind = .write,
    .run = print,
});

fn print(ctx: *publr.Ctx, in: PrintIn) publr.Error!PrintOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.label.len == 0 or in.label.len > 64) {
        return error.Invalid;
    }

    return .{
        .label = in.label,
        .fails = in.fails,
    };
}

/// Sends each label to the printer
///
/// Fails:
/// - Offline (503): the printer is offline
fn send(ctx: *publr.QueueCtx, out: PrintOut) publr.Error!void {
    std.debug.assert(out.label.len > 0);

    _ = try Tries.create(ctx, .{
        .label = out.label,
    });

    const tried = try tried_of.execute(ctx, u32, .{
        .label = out.label,
    });

    ctx.log(.info, "Sending {s}, try {d}", .{ out.label, tried });

    if (tried <= out.fails) {
        return ctx.fail(.Offline, "The printer is offline.", .{});
    }

    ctx.log(.info, "Printed {s}", .{out.label});
}

/// Files a copy of each label
fn file_copy(ctx: *publr.QueueCtx, out: PrintOut) publr.Error!void {
    std.debug.assert(out.label.len > 0);

    ctx.log(.info, "Filed a copy of {s}", .{out.label});
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Tries},
    .operations = &.{Print},
    .hooks = &.{
        publr.on(Print, send),
        publr.on(Print, file_copy),
    },
});
