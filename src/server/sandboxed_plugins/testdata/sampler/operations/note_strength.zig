//! Draws the sampler's help under a sample note's text, by its own view: how full the
//! note is, following the text as it is typed.
//!
//! Example:
//!   in: { "record": "" }
//!   out: { "html": "<!doctype html>" }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {
    /// The note the form is open on; empty on a new one
    record: []const u8,
    /// The path the project is served under
    base: []const u8 = "",
};

pub const Out = struct {
    /// The help's markup
    html: []const u8,
};

/// An id of up to 64 characters.
fn check(in: In, problems: *publr.Problems(In)) void {
    if (in.record.len > 64) {
        problems.add(.record, "An id is at most 64 characters.");
    }
}

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    std.debug.assert(in.record.len <= 64);
    std.debug.assert(in.base.len <= 1024);

    return .{
        .html = try publr.views.render(ctx, in.base, publr.views.all.SamplerNoteStrength, .{}),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "note_strength",
    .kind = .read,
    .validate = check,
    .run = run,
});
