//! What other servers sent to plugins' webhooks (`publr.webhook.define`): each plugin's
//! webhooks with the address to paste, its deliveries, and Run again.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const public = @import("../publr/operations/webhook.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const Webhook = public.Webhook;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.RunAgain;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
