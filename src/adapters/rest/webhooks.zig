//! `/_webhooks/<plugin>.<name>`: what other servers send to a plugin's webhook. The signature
//! is checked on the raw bytes with the plugin's declared secret, the body read as its event,
//! a delivery seen before dropped; the delivery is kept, its run queued, and 200 answered at
//! once. Unsigned or wrongly signed is refused with 401, a body that does not read with 400;
//! both are kept, so the plugin's Webhooks tab shows them.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const http = @import("../../lib/http.zig");
const store = @import("../../store.zig");
const secret = @import("../../operations/secret.zig");
const identity = @import("identity.zig");
const webhook_define = @import("../../sdk/plugin/webhook_define.zig");
const Project = @import("../../server/project.zig").Project;

const Request = http.Request;
const Response = http.Response;
const Context = http.Context;

pub const prefix = "/_webhooks/";

/// The route over a webhook list, so the registry's and a test's are the same code.
pub fn Receive(comptime webhooks: []const type, comptime owners: []const []const u8) type {
    comptime std.debug.assert(webhooks.len == owners.len);

    return struct {
        pub const routes_count: u32 = 1;

        pub fn register(router: *http.Router) void {
            std.debug.assert(router.routes_len < router.routes.len - routes_count);

            router.post(prefix ++ ":name", &receive);
        }

        fn receive(request: *Request, response: *Response, ctx: *Context) anyerror!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            const address = request.param("name") orelse "";

            inline for (webhooks, owners) |Webhook, owner| {
                if (std.mem.eql(u8, address, owner ++ "." ++ Webhook.name)) {
                    return take(.{
                        .owner = owner,
                        .webhook = .{
                            .name = Webhook.name,
                            .secret = Webhook.secret,
                            .signature = Webhook.signature,
                            .body = Webhook.body,
                            .delivery_id = Webhook.delivery_id,
                        },
                        .readable = Readable(Webhook).check,
                    }, request, response, ctx);
                }
            }

            // An installed plugin's: its sandbox reads the body as its event when it runs.
            const sandboxed = Project.of(ctx).sandboxed_plugins orelse {
                return response.text(.not_found, "No such webhook");
            };

            for (sandboxed.manifests()) |manifest| {
                for (manifest.webhooks) |webhook| {
                    const same = std.mem.startsWith(u8, address, manifest.name) and
                        address.len == manifest.name.len + 1 + webhook.name.len and
                        address[manifest.name.len] == '.' and
                        std.mem.endsWith(u8, address, webhook.name);

                    if (same) {
                        return take(.{
                            .owner = manifest.name,
                            .webhook = webhook,
                            .readable = webhook_define.readable,
                        }, request, response, ctx);
                    }
                }
            }

            return response.text(.not_found, "No such webhook");
        }
    };
}

/// A compiled-in webhook's body checked as its event reads it.
fn Readable(comptime Webhook: type) type {
    return struct {
        fn check(body: webhook_define.Body, arena: std.mem.Allocator, bytes: []const u8) bool {
            std.debug.assert(body == Webhook.body);

            _ = webhook_define.read(Webhook.Payload, Webhook.body, arena, bytes, "") catch {
                return false;
            };

            return true;
        }
    };
}

/// The webhook a delivery is for, wherever it is declared.
const Target = struct {
    owner: []const u8,
    webhook: webhook_define.wire.Webhook,
    readable: *const fn (webhook_define.Body, std.mem.Allocator, []const u8) bool,
};

fn take(target: Target, request: *Request, response: *Response, ctx: *Context) anyerror!void {
    std.debug.assert(target.owner.len > 0);
    std.debug.assert(ctx.user_data != null);

    const webhook = target.webhook;
    const owner = target.owner;
    const body = request.body;

    if (body.len > webhook_define.body_bytes_max) {
        return response.text(.payload_too_large, "Too large");
    }

    const arena = ctx.arena;
    const project = Project.of(ctx);
    var system = identity.context(project, arena, .system);
    const headers = try headers_of(arena, request);
    const key = secret.value_of(&system, webhook.secret) catch null;
    var delivery: store.webhook_deliveries.Received = .{
        .plugin = owner,
        .name = webhook.name,
        .delivery_id = "",
        .received_at = system.now_ms,
        .sender = sdk.limits.address_of(arena, request.peer(), request.header("x-forwarded-for")),
        .verified = false,
        .body = "",
        .headers = "",
        .result = "refused",
    };

    const signed = webhook_define.verified(
        webhook.signature,
        key orelse "",
        body,
        headers,
        system.now_ms,
    );

    if (!signed) {
        std.log.warn("webhook {s}.{s}: refused, its signature did not verify", .{
            owner,
            webhook.name,
        });
        _ = try store.webhook_deliveries.add(system.db, delivery);

        return response.text(.unauthorized, "Signature not verified");
    }

    delivery.verified = true;
    delivery.body = body;
    delivery.headers = headers;

    if (!target.readable(webhook.body, arena, body)) {
        std.log.warn("webhook {s}.{s}: its body does not read", .{ owner, webhook.name });
        delivery.result = "unreadable";
        _ = try store.webhook_deliveries.add(system.db, delivery);

        return response.text(.bad_request, "The body does not read");
    }

    delivery.delivery_id = webhook_define.delivery_id_of(
        webhook.delivery_id,
        webhook.body,
        arena,
        body,
        headers,
    );

    if (delivery.delivery_id.len > 0) {
        const repeat = try store.webhook_deliveries.seen(
            system.db,
            owner,
            webhook.name,
            delivery.delivery_id,
        );

        if (repeat) {
            return response.text(.ok, "Received before");
        }
    }

    delivery.result = "waiting";
    try keep(&system, owner, webhook.name, delivery);

    return response.text(.ok, "Received");
}

/// The delivery kept and its run queued, together.
fn keep(
    system: *sdk.Ctx,
    owner: []const u8,
    name: []const u8,
    delivery: store.webhook_deliveries.Received,
) store.webhook_deliveries.Error!void {
    std.debug.assert(delivery.verified);
    std.debug.assert(system.db.transaction_depth == 0);

    var transaction = try system.db.transaction();
    errdefer transaction.rollback();

    const id = try store.webhook_deliveries.add(system.db, delivery);

    try store.job_queue.push(system.db, .{
        .plugin = owner,
        .name = try std.fmt.allocPrint(system.arena, "webhook_{s}", .{name}),
        .input = try std.fmt.allocPrint(system.arena, "{{\"delivery\":{d}}}", .{id}),
        .due_at_ms = system.now_ms,
        .now_ms = system.now_ms,
    });
    try transaction.commit();
}

/// The request's headers as `name: value` lines, its credentials left out.
fn headers_of(arena: std.mem.Allocator, request: *const Request) error{OutOfMemory}![]const u8 {
    const inner = request.inner;

    std.debug.assert(inner.headers_len <= inner.headers.len);

    var lines: std.ArrayList(u8) = .empty;

    for (inner.headers[0..inner.headers_len]) |header| {
        const credential = std.ascii.eqlIgnoreCase(header.name, "cookie") or
            std.ascii.eqlIgnoreCase(header.name, "authorization");

        if (!credential) {
            try lines.print(arena, "{s}: {s}\n", .{ header.name, header.value });
        }
    }

    return lines.items;
}

test "a signed delivery runs as queued work, a repeat is dropped, a forged one refused" {
    const registry = @import("../../server/registry.zig");
    const Paid = struct {
        id: []const u8,
        order: []const u8,
    };
    const Probe = struct {
        fn run(ctx: anytype, paid: Paid) sdk.Error!void {
            std.debug.assert(paid.id.len > 0);

            ctx.log(.info, "Order {s} paid", .{paid.order});
            ctx.base.inner.dependency_failure = std.mem.eql(u8, paid.order, "1042");
        }
    };
    const Hook = webhook_define.define(Paid, .{
        .name = "paid",
        .secret = "SHOP_WEBHOOK_KEY",
        .signature = .{
            .token = .{
                .header = "X-Shop-Token",
            },
        },
        .delivery_id = .{
            .field = "id",
        },
        .run = Probe.run,
    });
    const Route = Receive(&.{Hook}, &.{"shop"});
    const Runner = sdk.SDK(.{
        .operations = &.{},
        .jobs = &.{Hook},
        .job_owners = &.{"shop"},
    }).jobs;

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Environment = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };

    // The secret's value from the environment, as a site may give it.
    try std.testing.expectEqual(0, Environment.setenv("SHOP_WEBHOOK_KEY", "t0ken", 1));
    defer _ = Environment.unsetenv("SHOP_WEBHOOK_KEY");

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    var project: Project = .{
        .connection = &harness.fixture.connection,
        .auth = &harness.auth,
        .io = std.testing.io,
    };
    var app = http.App.offline(.{});
    app.user_data = &project;
    Route.register(app.router());

    const body = "{\"id\":\"evt_1\",\"order\":\"1042\"}";
    const signed = "POST /_webhooks/shop.paid HTTP/1.1\r\nHost: h\r\nX-Shop-Token: t0ken\r\n" ++
        "Content-Length: 29\r\n\r\n";
    const forged = "POST /_webhooks/shop.paid HTTP/1.1\r\nHost: h\r\nX-Shop-Token: guess\r\n" ++
        "Content-Length: 29\r\n\r\n";

    try std.testing.expectEqual(200, (try send(&app, arena, signed, body)).status.code());
    try std.testing.expectEqual(200, (try send(&app, arena, signed, body)).status.code());
    try std.testing.expectEqual(401, (try send(&app, arena, forged, body)).status.code());

    const missing = "POST /_webhooks/shop.other HTTP/1.1\r\nHost: h\r\nContent-Length: 0\r\n\r\n";

    try std.testing.expectEqual(404, (try send(&app, arena, missing, "")).status.code());

    // One run queued: the repeat was dropped. It runs as the plugin, with the body as its event.
    system.now_ms = sdk.context.wall_clock_ms(std.testing.io) + 1000;
    try std.testing.expectEqual(1, try Runner.drain(&system, 8));
    try std.testing.expectEqual(0, try Runner.drain(&system, 8));
    try std.testing.expect(system.dependency_failure);

    const listed = try store.webhook_deliveries.list(system.db, arena, "shop", 8);

    try std.testing.expectEqual(2, listed.len);
    try std.testing.expectEqualStrings("refused", listed[0].result);
    try std.testing.expectEqualStrings("ran", listed[1].result);
    try std.testing.expect(std.mem.indexOf(u8, listed[1].lines, "Order 1042 paid") != null);
}

fn send(
    app: *http.App,
    arena: std.mem.Allocator,
    head: []const u8,
    body: []const u8,
) !http.Response {
    std.debug.assert(head.len > 0);

    const parsed = try http.parse(head);
    const wire = parsed.complete;
    var request: http.Request = .{
        .inner = &wire,
        .body = body,
    };

    return app.handle(arena, &request);
}
