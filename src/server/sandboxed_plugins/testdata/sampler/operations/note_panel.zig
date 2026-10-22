//! Draws the sampler's box on a sample note's form, by its own view.
//!
//! It is told only the record's id and reads the rest itself: which record it was told, and
//! how many notes there are, drawn on the panel layout as its pages are drawn on theirs.
//!
//! Example:
//!   in: { "record": "0190f7a2c3d4" }
//!   out: { "html": "<!doctype html>" }
const publr = @import("publr");
const std = @import("std");

const Notes = @import("../records/notes.zig");

pub const In = struct {
    /// The note the form is open on
    record: []const u8,
    /// The path the project is served under
    base: []const u8 = "",
};

pub const Out = struct {
    /// The box's markup
    html: []const u8,
};

/// An id of 1 to 64 characters.
fn check(in: In, problems: *publr.Problems(In)) void {
    if (in.record.len == 0 or in.record.len > 64) {
        problems.add(.record, "An id is 1 to 64 characters.");
    }
}

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.record.len > 0);
    std.debug.assert(in.record.len <= 64);

    const all = try Notes.typed.find(ctx, .{}, .{
        .limit = 200,
    });

    return .{
        .html = try publr.views.render(ctx, in.base, publr.views.all.SamplerNotePanel, .{
            .record = in.record,
            .total = @floatFromInt(all.len),
        }),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "note_panel",
    .kind = .read,
    .validate = check,
    .run = run,
});
