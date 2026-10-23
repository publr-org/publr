//! `publr.webhook.define(Event, .{ .name, .secret, .signature, .run })`: what another server
//! sends to `/_webhooks/<plugin>.<name>`. Core checks the signature on the raw bytes with the
//! plugin's declared secret, answers 200 at once and runs `run` as queued work with the body
//! read as `Event`: JSON, a form (`.body = .form`), or the bytes as they came (`.body = .raw`,
//! `Event` a `publr.webhook.Delivery`). Not an operation: no caller, no `.authorize`; the
//! signature is its only credential. Listed in `.webhooks`, by built-in and installed plugins.
const std = @import("std");
const job_define = @import("job_define.zig");
const queue = @import("queue.zig");
const deliveries = @import("../../store/webhook_deliveries.zig");
const Error = @import("../operation.zig").Error;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// The most a delivery's body may hold; a longer one is refused.
pub const body_bytes_max: u32 = 256 << 10;
/// How far a timestamped signature's time may be from now.
pub const tolerance_ms: i64 = 5 * 60 * 1000;

pub const wire = @import("../../model/sandboxed_plugin.zig");

pub const Signature = wire.Signature;
pub const Encoding = wire.Encoding;
pub const Body = wire.Body;
pub const DeliveryId = wire.DeliveryId;

/// A delivery as it came, for `.body = .raw`: the body within the cap and its headers.
pub const Delivery = struct {
    body: []const u8,
    /// `name: value` lines.
    headers: []const u8,

    /// The first header of that name, case aside; null when there is none.
    pub fn header(delivery: Delivery, name: []const u8) ?[]const u8 {
        std.debug.assert(name.len > 0);

        return header_in(delivery.headers, name);
    }
};

pub fn define(comptime Event: type, comptime options: anytype) type {
    const Options = @TypeOf(options);

    comptime {
        for ([_][]const u8{ "name", "secret", "signature", "run" }) |field| {
            if (!@hasField(Options, field)) {
                @compileError("a webhook takes `.name`, `.secret`, `.signature` and `.run`");
            }
        }

        for (std.meta.fieldNames(Options)) |field| {
            const known = for ([_][]const u8{
                "name", "secret", "signature", "run", "body", "delivery_id",
            }) |one| {
                if (std.mem.eql(u8, one, field)) {
                    break true;
                }
            } else false;

            if (!known) {
                @compileError("a webhook takes `.name`, `.secret`, `.signature`, `.run`, " ++
                    "`.body` and `.delivery_id`, not `." ++ field ++ "`");
            }
        }

        if (options.name.len == 0 or std.mem.indexOfScalar(u8, options.name, '.') != null) {
            @compileError("a webhook's `.name` is one word under its plugin: " ++ options.name);
        }

        const raw = @hasField(Options, "body") and options.body == .raw;

        if ((Event == Delivery) != raw) {
            @compileError("webhook " ++ options.name ++ ": `.body = .raw` hands `run` a " ++
                "`publr.webhook.Delivery`, the body as it came; other bodies are read as `Event`");
        }
    }

    return struct {
        pub const is_webhook = true;
        pub const is_job = true;
        pub const Input = Queued;
        pub const Payload = Event;
        /// Its name under the plugin, and its queued run's.
        pub const name: []const u8 = options.name;
        pub const verb: []const u8 = "webhook_" ++ options.name;
        pub const secret: []const u8 = options.secret;
        pub const signature: Signature = union_of(Signature, options.signature);
        pub const body: Body = if (@hasField(Options, "body")) options.body else .json;
        pub const delivery_id: ?DeliveryId = if (@hasField(Options, "delivery_id"))
            union_of(DeliveryId, options.delivery_id)
        else
            null;
        pub const on_conflict = null;
        pub const every: ?job_define.Every = null;
        pub const at: job_define.At = .{};
        pub const due_on: ?job_define.Due = null;

        /// The delivery read as `Event` and handed to the plugin's `run`; what it logged is
        /// kept with the delivery, and so is how it ended.
        pub fn run(ctx: anytype, in: Queued) Error!void {
            std.debug.assert(in.delivery > 0);

            const base = queue.base_of(ctx);

            // In an installed plugin's sandbox the host hands the delivery over and keeps
            // how it ended.
            if (comptime !@hasField(std.meta.Child(@TypeOf(base)), "inner")) {
                const event = read(Event, body, base.arena(), in.body, in.headers) catch {
                    return error.Invalid;
                };

                return options.run(ctx, event);
            }

            const inner = base.inner;
            const kept = try deliveries.get(inner.db, inner.arena, in.delivery) orelse {
                return error.NotFound;
            };
            const event = read(Event, body, inner.arena, kept.body, kept.headers) catch {
                try settled(inner, in.delivery, "failed", "The body no longer reads as the event");

                return error.Invalid;
            };

            options.run(ctx, event) catch |err| {
                const said = if (inner.failure) |failure| failure.message else @errorName(err);

                try settled(inner, in.delivery, "waiting", said);

                return err;
            };

            try settled(inner, in.delivery, "ran", "");
        }

        /// Its last try failed: the delivery is kept as failed, with why.
        pub fn on_failure(ctx: anytype, in: Queued, err: Error) void {
            const base = queue.base_of(ctx);

            if (comptime !@hasField(std.meta.Child(@TypeOf(base)), "inner")) {
                return;
            }

            const inner = base.inner;
            const problem = if (inner.failure) |failure| failure.message else @errorName(err);

            std.debug.assert(problem.len > 0);

            settled(inner, in.delivery, "failed", problem) catch |failed| {
                std.log.warn("webhook {s}: delivery {d} not marked failed: {t}", .{
                    options.name,
                    in.delivery,
                    failed,
                });
            };
        }
    };
}

/// `.{ .hmac = .{ .header = "X-Signature" } }` as the union it names.
fn union_of(comptime Union: type, comptime given: anytype) Union {
    comptime {
        const Given = @TypeOf(given);

        if (Given == Union) {
            return given;
        }

        const fields = std.meta.fields(Given);

        if (fields.len != 1 or !@hasField(Union, fields[0].name)) {
            @compileError("a webhook's `" ++ @typeName(Union) ++ "` names one kind");
        }

        const tag = fields[0].name;
        const Payload = @FieldType(Union, tag);
        const value = @field(given, tag);

        if (Payload == []const u8) {
            return @unionInit(Union, tag, value);
        }

        var made: Payload = undefined;

        for (std.meta.fields(Payload)) |field| {
            @field(made, field.name) = if (@hasField(@TypeOf(value), field.name))
                @field(value, field.name)
            else
                field.defaultValue() orelse @compileError("a webhook's `." ++ tag ++
                    "` takes `." ++ field.name ++ "`");
        }

        return @unionInit(Union, tag, made);
    }
}

/// What a delivery's queued run carries: the delivery kept.
pub const Queued = struct {
    delivery: i64,
    /// For an installed plugin's run, which has no store to read the delivery from.
    body: []const u8 = "",
    headers: []const u8 = "",
};

/// The delivery's result and what its run logged.
pub fn settled(inner: anytype, id: i64, result: []const u8, problem: []const u8) Error!void {
    std.debug.assert(id > 0);
    std.debug.assert(result.len > 0);

    var logged: std.ArrayList(u8) = .empty;

    if (inner.lines) |lines| {
        for (lines.items.items) |line| {
            try logged.print(inner.arena, "{t}: {s}\n", .{ line.level, line.text });
        }
    }

    try deliveries.settle(inner.db, id, result, problem, logged.items);
}

pub fn is_webhook(comptime Candidate: type) bool {
    return @typeInfo(Candidate) == .@"struct" and @hasDecl(Candidate, "is_webhook");
}

/// The body read as `Event`: JSON or a form's fields, or the delivery as it came.
pub fn read(
    comptime Event: type,
    comptime body: Body,
    arena: std.mem.Allocator,
    bytes: []const u8,
    headers: []const u8,
) !Event {
    if (comptime body == .raw) {
        return .{
            .body = bytes,
            .headers = headers,
        };
    }

    const json = if (body == .form) try form_json(arena, bytes) else bytes;

    return std.json.parseFromSliceLeaky(Event, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// A form's fields as a JSON object of strings, the last of a repeated name kept.
fn form_json(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    std.debug.assert(bytes.len <= body_bytes_max);

    var object: std.json.ObjectMap = .empty;
    var pairs = std.mem.tokenizeScalar(u8, bytes, '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const value = if (equals < pair.len) pair[equals + 1 ..] else "";

        try object.put(arena, try decoded(arena, pair[0..equals]), .{
            .string = try decoded(arena, value),
        });
    }

    return std.json.Stringify.valueAlloc(arena, std.json.Value{
        .object = object,
    }, .{});
}

fn decoded(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    std.debug.assert(text.len <= body_bytes_max);

    const copy = try arena.dupe(u8, text);

    std.mem.replaceScalar(u8, copy, '+', ' ');

    return std.Uri.percentDecodeInPlace(copy);
}

/// Whether the body is signed with `secret` the way `signature` says.
pub fn verified(
    signature: Signature,
    secret: []const u8,
    body: []const u8,
    headers: []const u8,
    now_ms: i64,
) bool {
    std.debug.assert(body.len <= body_bytes_max);
    std.debug.assert(now_ms >= 0);

    if (secret.len == 0) {
        return false;
    }

    switch (signature) {
        .token => |token| {
            const given = header_in(headers, token.header) orelse return false;

            return same(given, secret);
        },
        .hmac => |hmac| {
            const given = header_in(headers, hmac.header) orelse return false;

            if (!std.mem.startsWith(u8, given, hmac.prefix)) {
                return false;
            }

            var mac: [HmacSha256.mac_length]u8 = undefined;

            HmacSha256.create(&mac, body, secret);

            return matches(&mac, given[hmac.prefix.len..], hmac.encoding);
        },
        .timestamped => |timestamped| {
            const given = header_in(headers, timestamped.header) orelse return false;

            return timestamped_verified(given, secret, body, now_ms);
        },
    }
}

/// `t=<seconds>,v1=<hex>[,v1=<hex>…]`: any `v1` over `<seconds>.<body>`, the time within
/// five minutes of now.
fn timestamped_verified(
    given: []const u8,
    secret: []const u8,
    body: []const u8,
    now_ms: i64,
) bool {
    std.debug.assert(secret.len > 0);
    std.debug.assert(now_ms >= 0);

    var seconds: ?[]const u8 = null;
    var parts = std.mem.tokenizeScalar(u8, given, ',');

    while (parts.next()) |part| {
        if (std.mem.startsWith(u8, part, "t=")) {
            seconds = part[2..];
        }
    }

    const time_text = seconds orelse return false;
    const at_s = std.fmt.parseInt(i64, time_text, 10) catch return false;

    if (@abs(now_ms - at_s * 1000) > tolerance_ms) {
        return false;
    }

    var mac: [HmacSha256.mac_length]u8 = undefined;
    var hmac = HmacSha256.init(secret);

    hmac.update(time_text);
    hmac.update(".");
    hmac.update(body);
    hmac.final(&mac);

    var signatures = std.mem.tokenizeScalar(u8, given, ',');

    while (signatures.next()) |part| {
        if (std.mem.startsWith(u8, part, "v1=") and matches(&mac, part[3..], .hex)) {
            return true;
        }
    }

    return false;
}

fn matches(mac: *const [HmacSha256.mac_length]u8, given: []const u8, encoding: Encoding) bool {
    std.debug.assert(given.len <= 1024);

    var expected: [HmacSha256.mac_length * 2]u8 = undefined;
    const shown: []const u8 = switch (encoding) {
        .hex => &std.fmt.bytesToHex(mac.*, .lower),
        .base64 => std.base64.standard.Encoder.encode(&expected, mac),
    };

    return same(std.mem.trim(u8, given, " "), shown);
}

/// Equal, in a time that does not tell how much of it matched.
fn same(given: []const u8, expected: []const u8) bool {
    std.debug.assert(expected.len > 0);

    if (given.len != expected.len) {
        return false;
    }

    var differ: u8 = 0;

    for (given, expected) |given_byte, expected_byte| {
        differ |= given_byte ^ expected_byte;
    }

    return differ == 0;
}

/// The first `name: value` line of that name, case aside.
pub fn header_in(headers: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);

    var lines = std.mem.tokenizeAny(u8, headers, "\r\n");

    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;

        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) {
            return std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }

    return null;
}

/// The delivery's own id, where the webhook says it is (`where`); empty when it says none
/// or the body does not have it.
pub fn delivery_id_of(
    where: ?DeliveryId,
    body: Body,
    arena: std.mem.Allocator,
    bytes: []const u8,
    headers: []const u8,
) []const u8 {
    std.debug.assert(bytes.len <= body_bytes_max);

    return switch (where orelse return "") {
        .header => |name| header_in(headers, name) orelse "",
        .field => |name| field_of(body, arena, bytes, name),
    };
}

/// Whether the body reads as its kind says: any JSON, any form, or any bytes. An installed
/// plugin's sandbox reads it as its event later.
pub fn readable(body: Body, arena: std.mem.Allocator, bytes: []const u8) bool {
    std.debug.assert(bytes.len <= body_bytes_max);

    const json = switch (body) {
        .raw => return true,
        .form => form_json(arena, bytes) catch return false,
        .json => bytes,
    };

    _ = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return false;

    return true;
}

fn field_of(body: Body, arena: std.mem.Allocator, bytes: []const u8, name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const json = if (body == .form) form_json(arena, bytes) catch return "" else bytes;
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return "";

    if (value != .object) {
        return "";
    }

    return switch (value.object.get(name) orelse return "") {
        .string => |text| text,
        .integer => |number| std.fmt.allocPrint(arena, "{d}", .{number}) catch "",
        else => "",
    };
}

test "signatures: an HMAC in a header, the timestamped kind, a token; wrong ones refused" {
    const body = "{\"id\":\"evt_1\"}";
    var mac: [HmacSha256.mac_length]u8 = undefined;

    HmacSha256.create(&mac, body, "s3cret");

    const hex = std.fmt.bytesToHex(mac, .lower);
    const signed = "X-Signature: sha256=" ++ hex;
    const hmac: Signature = .{
        .hmac = .{
            .header = "x-signature",
            .prefix = "sha256=",
        },
    };

    try std.testing.expect(verified(hmac, "s3cret", body, signed, 0));
    try std.testing.expect(!verified(hmac, "other", body, signed, 0));
    try std.testing.expect(!verified(hmac, "s3cret", "{}", signed, 0));
    try std.testing.expect(!verified(hmac, "s3cret", body, "", 0));

    var stamped: [HmacSha256.mac_length]u8 = undefined;
    var stamping = HmacSha256.init("whsec");

    stamping.update("1792405800." ++ body);
    stamping.final(&stamped);

    const header = "Stripe-Signature: t=1792405800,v1=bad,v1=" ++
        std.fmt.bytesToHex(stamped, .lower);
    const timestamped: Signature = .{
        .timestamped = .{
            .header = "Stripe-Signature",
        },
    };

    try std.testing.expect(verified(timestamped, "whsec", body, header, 1_792_405_860_000));
    try std.testing.expect(!verified(timestamped, "whsec", body, header, 1_792_406_800_000));

    const token: Signature = .{
        .token = .{
            .header = "X-Token",
        },
    };

    try std.testing.expect(verified(token, "abc", body, "X-Token: abc", 0));
    try std.testing.expect(!verified(token, "abc", body, "X-Token: abd", 0));
    try std.testing.expect(!verified(token, "", body, "X-Token: ", 0));
}

test "a form read as its event, and a delivery's id from a field" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const Notice = struct {
        order: []const u8,
        note: []const u8,
    };
    const Hook = define(Notice, .{
        .name = "notify",
        .secret = "SHOP_KEY",
        .signature = .{
            .token = .{
                .header = "X-Token",
            },
        },
        .body = .form,
        .delivery_id = .{
            .field = "order",
        },
        .run = struct {
            fn run(_: *anyopaque, _: Notice) error{Failed}!void {}
        }.run,
    });
    const notice = try read(Notice, Hook.body, arena, "order=A%2F1&note=paid+in+full", "");

    try std.testing.expectEqualStrings("A/1", notice.order);
    try std.testing.expectEqualStrings("paid in full", notice.note);
    try std.testing.expectEqualStrings("A/1", delivery_id_of(
        Hook.delivery_id,
        Hook.body,
        arena,
        "order=A%2F1",
        "",
    ));
    try std.testing.expectEqualStrings("webhook_notify", Hook.verb);
    try std.testing.expect(is_webhook(Hook) and job_define.is_job(Hook));
}
