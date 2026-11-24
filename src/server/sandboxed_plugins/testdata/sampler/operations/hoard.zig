//! Hold kibibytes in a list.
//!
//! Appends `count` items of a kibibyte each to one `publr.List`: past what the plugin may
//! hold it runs out of memory, and the line it leaves names the list. Administrators may
//! call it.
//!
//! Example:
//!   in: { "count": 3 }
//!   out: { "held": 3 }
const publr = @import("publr");
const std = @import("std");

const Kibibyte = struct {
    bytes: [1024]u8,
};

pub const In = struct {
    /// How many kibibytes to hold
    count: u32,
};

pub const Out = struct {
    /// How many the list held
    held: u32,
};

/// More than any plugin may hold: 256 MiB.
const count_max: u32 = 256 * 1024;

fn run(ctx: *publr.Ctx, in: In) publr.Error!Out {
    var hoard = publr.List(Kibibyte).init(ctx);

    std.debug.assert(ctx.now().ms >= 0);

    if (in.count > count_max) {
        return error.Invalid;
    }

    for (0..in.count) |index| {
        try hoard.append(.{
            .bytes = @splat(@truncate(index)),
        });
    }

    return .{
        .held = hoard.len(),
    };
}

pub const operation = publr.operation.define(In, Out, .{
    .name = "hoard",
    .kind = .read,
    .run = run,
});
