//! An installed plugin core's tests and smoke install: greetings kept as records.
//!
//! The next version of `greeter`, as tests and parity update to it: it asks for more (a
//! high-tier permission), so the update waits for an administrator.
//! The next version of the plugin the sandbox is tested with.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;

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

const permissions = [_]publr.plugin.Permission{
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

pub const Count = struct {
    pub const name = "greeter.count";
    pub const description = "Count the greetings";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        /// Why: a count, not money
        total: u32,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .total = 1,
    };

    pub fn run(ctx: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now().ms >= 0);

        const record = publr.operations.record;
        const all = try ctx.call(record.List, .{
            .type = "greeter.salutation",
            .limit = 200,
        });

        return .{
            .total = @intCast(all.records.len),
        };
    }
};

pub const plugin = publr.plugin.define(manifest, .{
    .records = &.{Salutations},
    .permissions = permissions,
    .operations = operations,
});
