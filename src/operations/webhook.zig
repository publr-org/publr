//! What other servers sent to plugins' webhooks (`publr.webhook.define`): each plugin's
//! webhooks with the address to paste, its deliveries, and Run again.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "webhook",
    .label = "Webhooks",
    .area = .system,
    .summary = "What other servers sent to plugins' webhooks",
    .details =
    \\A plugin's webhook is an address another server sends to:
    \\`/_webhooks/<plugin>.<name>`. Publr checks the signature with the plugin's secret,
    \\answers at once and runs the plugin's code as queued work. Every delivery is kept:
    \\when it came, whether its signature held, how its run ended and what it logged.
    ,
};

pub const Webhook = struct {
    name: []const u8,
    /// The address, below the site's: `/_webhooks/<plugin>.<name>`.
    path: []const u8,
};

pub const List = struct {
    pub const name = "webhook.list";
    pub const description = "A plugin's webhooks and what was sent to them, newest first";
    pub const details =
        \\Administrators only. Each webhook with its address, then the last 100 deliveries:
        \\when, from where, whether the signature held, and the result: `waiting` (to run),
        \\`ran`, `failed` (after every try), `refused` (signature) or `unreadable` (body).
        \\Changes nothing.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        plugin: []const u8,
    };
    pub const Out = struct {
        webhooks: []const Webhook,
        deliveries: []const store.webhook_deliveries.Listed,
    };
    pub const example: In = .{
        .plugin = "shop",
    };
    pub const example_out: Out = .{
        .webhooks = &.{.{
            .name = "paid",
            .path = "/_webhooks/shop.paid",
        }},
        .deliveries = &.{.{
            .id = 3,
            .name = "paid",
            .delivery_id = "evt_1",
            .received_at = 1_790_000_000_000,
            .sender = "203.0.113.9",
            .verified = true,
            .result = "ran",
            .problem = "",
            .lines = "info: Order 1042 paid\n",
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .plugin = "The plugin, `shop`",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .webhooks = "Each webhook's name and its address below the site's",
        .deliveries = "Newest first: id, webhook, the sender's id for it, when, from where, " ++
            "whether the signature held, the result, why it failed, what its run logged",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.plugin.len == 0 or in.plugin.len > 64) {
            return error.Invalid;
        }

        const registry = @import("../server/registry.zig");
        var webhooks: std.ArrayList(Webhook) = .empty;

        inline for (registry.webhooks, registry.webhook_owners) |Declared, owner| {
            if (std.mem.eql(u8, owner, in.plugin)) {
                try webhooks.append(ctx.arena, .{
                    .name = Declared.name,
                    .path = "/_webhooks/" ++ owner ++ "." ++ Declared.name,
                });
            }
        }

        if (ctx.sandboxed_plugins) |sandboxed| {
            for (sandboxed.manifests()) |manifest| {
                if (!std.mem.eql(u8, manifest.name, in.plugin)) {
                    continue;
                }

                for (manifest.webhooks) |declared| {
                    try webhooks.append(ctx.arena, .{
                        .name = declared.name,
                        .path = try std.fmt.allocPrint(ctx.arena, "/_webhooks/{s}.{s}", .{
                            in.plugin,
                            declared.name,
                        }),
                    });
                }
            }
        }

        return .{
            .webhooks = webhooks.items,
            .deliveries = try store.webhook_deliveries.list(ctx.db, ctx.arena, in.plugin, 100),
        };
    }
};

pub const RunAgain = struct {
    pub const name = "webhook.run_again";
    pub const description = "Run a delivery's queued work again";
    pub const details =
        \\Administrators only. The plugin's code runs again on the delivery as it came, as
        \\queued work, its tries counted afresh. Only a delivery whose signature held.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        delivery: i64,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .delivery = 3,
    };
    pub const example_out: Out = .{};
    pub const field_docs: sdk.operation.Docs(In) = .{
        .delivery = "The delivery's id, from `webhook.list`",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.delivery <= 0) {
            return error.Invalid;
        }

        const deliveries = store.webhook_deliveries;
        const kept = try deliveries.get(ctx.db, ctx.arena, in.delivery) orelse {
            return error.NotFound;
        };

        if (!kept.verified) {
            return error.Invalid;
        }

        try store.webhook_deliveries.settle(ctx.db, in.delivery, "waiting", "", "");
        try store.job_queue.push(ctx.db, .{
            .plugin = kept.plugin,
            .name = try std.fmt.allocPrint(ctx.arena, "webhook_{s}", .{kept.name}),
            .input = try std.fmt.allocPrint(ctx.arena, "{{\"delivery\":{d}}}", .{
                in.delivery,
            }),
            .due_at_ms = ctx.now_ms,
            .now_ms = ctx.now_ms,
        });

        return .{};
    }
};

pub const operations = [_]type{ List, RunAgain };
