//! An installed plugin core's tests and smoke install: greetings kept as records.
//!
//! The next version of `greeter`, as tests and parity update to it: it asks for more (a
//! high-tier permission), so the update waits for an administrator.
//! The next version of the plugin the sandbox is tested with.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "greeter",
    .version = "0.2.0",
};

/// Salutation
///
/// A greeting someone recorded.
pub const Salutation = struct {
    /// Note
    note: []const u8,
};

pub const Salutations = publr.record.define(Salutation, .{
    .name = "greeter.salutation",
    .title_field = .note,
    .fields = .{
        .note = .{
            .validation = .{
                .required = true,
            },
        },
    },
});

const permissions = .{
    .{
        .key = "users.names",
        .reason = "Greets the people on the site by name",
    },
    .{
        .key = "users.read",
        .reason = "Greets people by their email address too",
    },
};

const operations = [_]type{Count};

pub const CountIn = struct {};

pub const CountOut = struct {
    /// How many greetings exist
    ///
    /// Why: a count, not money
    total: u32,
};

/// Count the greetings
///
/// Example:
///   in: {}
///   out: { "total": 1 }
pub const Count = publr.operation.define(CountIn, CountOut, .{
    .name = "count",
    .kind = .read,
    .run = count,
});

fn count(ctx: *publr.Ctx, _: CountIn) publr.Error!CountOut {
    std.debug.assert(ctx.now().ms >= 0);

    const all = try ctx.call(publr.operations.record.List, .{
        .type = "greeter.salutation",
        .limit = 200,
    });

    return .{
        .total = @intCast(all.records.len),
    };
}

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Salutations},
    .permissions = permissions,
    .operations = operations,
});
