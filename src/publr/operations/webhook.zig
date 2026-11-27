//! What other servers sent to plugins' webhooks (`publr.webhook.define`): each plugin's
//! webhooks with the address to paste, its deliveries, and Run again.
const operation = @import("../operation.zig");
const Delivery = @import("../model/webhook.zig").Delivery;

pub const namespace: operation.Namespace = .{
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
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        plugin: []const u8,
    };
    pub const Out = struct {
        webhooks: []const Webhook,
        deliveries: []const Delivery,
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
    pub const field_docs: operation.Docs(In) = .{
        .plugin = "The plugin, `shop`",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .webhooks = "Each webhook's name and its address below the site's",
        .deliveries = "Newest first: id, webhook, the sender's id for it, when, from where, " ++
            "whether the signature held, the result, why it failed, what its run logged",
    };
};

pub const RunAgain = struct {
    pub const name = "webhook.run_again";
    pub const description = "Run a delivery's queued work again";
    pub const details =
        \\Administrators only. The plugin's code runs again on the delivery as it came, as
        \\queued work, its tries counted afresh. Only a delivery whose signature held.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        delivery: i64,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .delivery = 3,
    };
    pub const example_out: Out = .{};
    pub const field_docs: operation.Docs(In) = .{
        .delivery = "The delivery's id, from `webhook.list`",
    };
};
