const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/mail.zig");
const model = @import("../model.zig");
const secret = @import("secret.zig");
const http_operations = @import("http.zig");
const request_log = @import("http_log.zig");
const outside = @import("../model/outside.zig");

pub const smtp = @import("mail/smtp.zig");
const conversation = @import("mail/conversation.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const secrets = model.secrets;

pub const namespace = public.namespace;

pub const operations = [_]type{Send};

pub const recipients_max = public.recipients_max;
pub const message_bytes_max = public.message_bytes_max;
const host_len_max: u32 = 253;
const credential_len_max: u32 = 1024;
const secrets_max: u32 = 4;

pub const Send = struct {
    pub const shape = public.Send;
    pub const name = shape.name;
    pub const plugins_only = shape.plugins_only;
    pub const secret = shape.secret;
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
        std.debug.assert(recipients_max > 0);

        const sender = http_operations.fetcher_of(ctx) orelse return error.Denied;

        // Nothing a request waits on reaches another server.
        if (ctx.job.len == 0) {
            return ctx.fail(http_operations.not_queued);
        }

        // Never inside a write: what the run wrote so far commits first.
        try @import("../sdk/job_write.zig").before_outside_call(ctx);

        try checked(ctx, in);

        const credentials = try filled(ctx, sender, in);

        return sent(ctx, sender.name, in, credentials);
    }
};

pub const not_allowed: sdk.operation.Failure = .{
    .name = "NotAllowed",
    .status = 403,
    .message = "A local or private address, the server itself, or no TLS, refused here",
};

fn checked(ctx: *Ctx, in: Send.In) Error!void {
    std.debug.assert(message_bytes_max > 0);

    const too_long = in.host.len == 0 or in.host.len > host_len_max or
        in.user.len > credential_len_max or in.password.len > credential_len_max;
    const recipients = in.to.len == 0 or in.to.len > recipients_max;

    const message_bad = in.message.len == 0 or in.message.len > message_bytes_max;
    const invalid = too_long or recipients or message_bad or in.port == 0;

    if (invalid or !conversation.envelope_address(in.from)) {
        return error.Invalid;
    }

    for (in.to) |recipient| {
        if (!conversation.envelope_address(recipient)) {
            return error.Invalid;
        }
    }

    if (in.security == .none and ctx.outside.production) {
        return ctx.fail(not_allowed);
    }
}

const Credentials = struct {
    user: []const u8,
    password: []const u8,
    names: []const []const u8,
    values: []const []const u8,
};

/// The user and password with their secrets filled in.
fn filled(ctx: *Ctx, sender: http_operations.Fetcher, in: Send.In) Error!Credentials {
    std.debug.assert(sender.name.len > 0);

    var storage: [secrets_max][]const u8 = undefined;
    const both = try std.mem.concat(ctx.arena, u8, &.{ in.user, in.password });
    const found = secrets.names_in(both, &storage) catch return error.Invalid;
    const names = try ctx.arena.dupe([]const u8, found);
    const values = try ctx.arena.alloc([]const u8, names.len);

    std.debug.assert(names.len <= secrets_max);

    for (names, values) |secret_name, *value| {
        const declared = secrets.declared_find(sender.access.secrets, secret_name) orelse {
            return ctx.fail(.{
                .name = "SecretNotDeclared",
                .status = 403,
                .message = "The plugin names a secret it does not declare in .secrets",
            });
        };

        value.* = try secret.value_of(ctx, secret_name) orelse {
            return ctx.fail(.{
                .name = "SecretMissing",
                .status = 409,
                .message = try std.fmt.allocPrint(ctx.arena, "{s} isn't set", .{
                    declared.label,
                }),
            });
        };
    }

    return .{
        .user = try fill(ctx, in.user, names, values),
        .password = try fill(ctx, in.password, names, values),
        .names = names,
        .values = values,
    };
}

fn fill(
    ctx: *Ctx,
    text: []const u8,
    names: []const []const u8,
    values: []const []const u8,
) Error![]const u8 {
    std.debug.assert(names.len == values.len);
    std.debug.assert(text.len <= credential_len_max);

    if (names.len == 0) {
        return text;
    }

    return secrets.fill(ctx.arena, text, names, values) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

fn sent(ctx: *Ctx, plugin: []const u8, in: Send.In, credentials: Credentials) Error!Send.Out {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(in.to.len > 0);

    if (builtin.os.tag == .wasi) {
        return error.Unavailable;
    }

    const started = std.Io.Clock.awake.now(ctx.io);
    const result = smtp.send(ctx.io, ctx.arena, .{
        .host = in.host,
        .port = in.port,
        .security = in.security,
        .user = credentials.user,
        .password = credentials.password,
        .from = in.from,
        .to = in.to,
        .message = in.message,
        .greeting = greeting_of(ctx.outside),
        .rule = ctx.outside,
    }, smtp.timeout_ms) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TimedOut => smtp.Result{
            .failed = .unreachable_server,
            .said = "no answer in 30 seconds",
        },
    };
    const said = try scrubbed(ctx, credentials, result.said);
    const failure = result.failed orelse {
        try logged(ctx, plugin, in, .info, said, started);
        return .{
            .sent = true,
            .reply = said,
        };
    };
    const why = if (result.refusal) |refusal| refusal.text() else @tagName(failure);

    try logged(ctx, plugin, in, .warn, if (said.len > 0) said else why, started);

    return switch (failure) {
        .refused_address => ctx.fail(not_allowed),
        .out_of_memory => error.OutOfMemory,
        else => .{
            .sent = false,
            .reply = try refusal_text(ctx, failure, said),
        },
    };
}

fn refusal_text(ctx: *Ctx, failure: smtp.Failure, said: []const u8) Error![]const u8 {
    std.debug.assert(failure != .refused_address);
    std.debug.assert(said.len <= 4096);

    return switch (failure) {
        .tls => try std.fmt.allocPrint(ctx.arena, "TLS with the mail server failed: {s}", .{
            said,
        }),
        .unreachable_server => if (said.len > 0)
            try std.fmt.allocPrint(ctx.arena, "The mail server gave {s}", .{said})
        else
            "The mail server could not be reached",
        .no_starttls => "The mail server offers no STARTTLS",
        .no_sign_in => "The mail server offers no sign-in Publr speaks (PLAIN or LOGIN)",
        else => try std.fmt.allocPrint(ctx.arena, "The mail server said: {s}", .{said}),
    };
}

/// What the server said with every secret's value put back as `{secret:NAME}`.
fn scrubbed(ctx: *Ctx, credentials: Credentials, text: []const u8) Error![]const u8 {
    std.debug.assert(credentials.names.len == credentials.values.len);
    std.debug.assert(text.len <= 4096);

    var result = text;

    for (credentials.names, credentials.values) |secret_name, value| {
        if (value.len == 0) {
            continue;
        }

        const marker = try std.fmt.allocPrint(ctx.arena, "{{secret:{s}}}", .{secret_name});

        result = try std.mem.replaceOwned(u8, ctx.arena, result, value, marker);
    }

    return result;
}

fn logged(
    ctx: *Ctx,
    plugin: []const u8,
    in: Send.In,
    level: sdk.trail.Level,
    outcome: []const u8,
    started: std.Io.Timestamp,
) Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(outcome.len > 0);

    const elapsed = started.durationTo(std.Io.Clock.awake.now(ctx.io));
    const ms: i64 = @intCast(@divTrunc(@max(0, elapsed.nanoseconds), std.time.ns_per_ms));
    const text = try std.fmt.allocPrint(ctx.arena, "SMTP {s}:{d} to {d}: {s} ({d} ms)", .{
        in.host,
        in.port,
        in.to.len,
        outcome,
        ms,
    });

    request_log.add(ctx, plugin, level, text);
}

/// The name the server is greeted with: the site's own host, else `localhost`.
fn greeting_of(rule: outside.Rule) []const u8 {
    std.debug.assert(rule.own_hosts.len <= 16);

    for (rule.own_hosts) |host| {
        if (host.len > 0 and !outside.this_machine(host)) {
            return host;
        }
    }

    return "localhost";
}

test "mail.send is refused outside queued work, whatever the plugin is granted" {
    const registry = @import("../server/registry.zig");
    const plugin_access = @import("../sdk/plugin_access.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    const held = [_]model.permission.Held{.{
        .key = "mail.send",
    }};
    const access: plugin_access.Access = .{
        .held = &held,
        .own_types = &.{},
    };
    var plugin = harness.ctx(.{
        .plugin = .{
            .name = "courier",
            .access = &access,
        },
    });
    const result = registry.SDK.dispatch(&plugin, Send, Send.example);

    try std.testing.expectError(error.Failed, result);
    try std.testing.expectEqualStrings("NotQueued", plugin.failure.?.name);
}

test {
    _ = smtp;
    _ = conversation;
}
