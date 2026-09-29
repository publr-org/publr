//! The next version of `greeter`, as tests and parity update to it: it asks for more (a
//! high-tier permission), so the update waits for an administrator.
const std = @import("std");
const publr = @import("publr");

const sdk = publr.sdk;
const PluginCtx = publr.plugin.PluginCtx;

pub const manifest: publr.plugin.Manifest = .{
    .name = "greeter",
    .version = "0.2.0",
    .summary = "An installed plugin core's tests and smoke install: greetings kept as records",
};

pub const namespaces = [_]sdk.operation.Namespace{.{
    .name = "greeter",
    .summary = "Greetings, kept as records of the plugin's own type",
    .details = "The next version of the plugin the sandbox is tested with.",
}};

pub const content_types = [_]publr.plugin.ContentTypeDef{.{
    .handle = "salutation",
    .name = "Salutation",
    .title_field = "note",
    .fields = &.{.{ .name = "note", .label = "Note", .kind = "string", .required = true }},
}};

pub const permissions = [_]publr.plugin.Permission{
    .{ .key = "users.names", .reason = "Greets the people on the site by name" },
    .{ .key = "users.read", .reason = "Greets people by their email address too" },
};

pub const operations = [_]type{Count};

pub const Count = struct {
    pub const name = "greeter.count";
    pub const description = "Count the greetings";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { total: u32 };
    pub const example: In = .{};
    pub const example_out: Out = .{ .total = 1 };

    pub fn run(ctx: *PluginCtx, _: In, _: *const sdk.Grant) sdk.Error!Out {
        std.debug.assert(ctx.now_ms() >= 0);

        const record = publr.operations.record;
        const all = try ctx.call(record.List, .{ .type = "salutation", .limit = 200 });

        return .{ .total = @intCast(all.records.len) };
    }
};
