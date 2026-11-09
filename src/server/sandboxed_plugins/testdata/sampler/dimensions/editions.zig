//! The sampler's editions of its content
//!
//! The dimension the sampler declares: a field may keep one value for the web, the
//! main edition, and another for print. Answers every edition, the web first.
//!
//! Example:
//!   in: {}
//!   out: { "values": [{ "code": "web", "label": "Web", "address": "", "main": true },
//!     { "code": "print", "label": "Print", "address": "/print", "main": false }] }
const publr = @import("publr");
const std = @import("std");

pub const In = struct {};

pub const Out = struct {
    /// Every edition, the main one first
    values: []const publr.dimension.Value,
};

const editions = [_]publr.dimension.Value{
    .{
        .code = "web",
        .label = "Web",
        .main = true,
    },
    .{
        .code = "print",
        .label = "Print",
        .address = "/print",
    },
};

fn run(ctx: *publr.Ctx, _: In) publr.Error!Out {
    std.debug.assert(ctx.now().ms >= 0);
    std.debug.assert(editions[0].main);

    return .{
        .values = &editions,
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "editions",
    .kind = .read,
    .run = run,
});

/// A field kept per edition: the setting on every field, and the admin's picker.
pub const dimension = publr.dimension.define(.{
    .name = "edition",
    .api = @import("edition_api.zig"),
    .list = operation,
});
