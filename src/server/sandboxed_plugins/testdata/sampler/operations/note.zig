//! Keep a note, in capitals.
//!
//! Administrators may call it. The before hook puts the note in capitals.
//!
//! Example:
//!   in: { "note": "hello" }
//!   out: { "note": "HELLO", "total": 1 }
const publr = @import("publr");
const std = @import("std");

const Notes = @import("../records/notes.zig");
const Tallies = @import("../records/tallies.zig");

pub const In = struct {
    /// What the note says
    note: []const u8,
};

pub const Out = struct {
    /// The note as kept
    note: []const u8,
    /// How many notes there are
    /// Why: a count, not money
    total: u32,
};

/// A note of 1 to 280 characters.
fn check(in: In, problems: *publr.Problems(In)) void {
    if (in.note.len == 0 or in.note.len > 280) {
        problems.add(.note, "A note is 1 to 280 characters.");
    }
}

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.note.len > 0);
    std.debug.assert(in.note.len <= 280);

    _ = try Notes.typed.create(ctx, .{
        .note = in.note,
    }, .{});
    _ = try Tallies.typed.create(ctx, .{
        .word = in.note,
    });

    const counted = try Tallies.typed.find(ctx, .{
        .word = in.note,
    }, .{});

    std.debug.assert(counted.len > 0);

    const all = try ctx.call(publr.operations.record.List, .{
        .type = "sampler.sample_note",
        .limit = 200,
    });

    return .{
        .note = in.note,
        .total = @intCast(all.records.len),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "note",
    .kind = .write,
    .validate = check,
    .run = run,
});
