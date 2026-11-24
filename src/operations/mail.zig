const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../sdk.zig");
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

pub const namespace: sdk.operation.Namespace = .{
    .name = "mail",
    .label = "Outside mail",
    .area = .system,
    .summary = "Email a plugin hands to a mail server over SMTP",
    .details =
    \\From queued work alone (a job, an `on` hook), never a request someone waits on, a
    \\plugin granted `mail.send` hands an email to the SMTP server it names: over TLS after
    \\STARTTLS or from the start, the certificate checked, signed in when it gives a user,
    \\or in development with no TLS. In production local and private addresses and the
    \\server itself are refused, and so is a site whose host sends everything out through
    \\its proxy. `{secret:NAME}` in the user or the password is filled in as it leaves, when
    \\the plugin declares it in `.secrets`. Each email is logged (server, recipients'
    \\count, the server's answer). Plugins only: a messaging provider is how Publr's own
    \\emails reach SMTP.
    ,
};

pub const operations = [_]type{Send};

/// Recipients of one email, at most.
pub const recipients_max: u32 = 50;
/// What one email may be, headers and attachments included.
pub const message_bytes_max: u32 = 8 << 20;
const host_len_max: u32 = 253;
const credential_len_max: u32 = 1024;
const secrets_max: u32 = 4;

pub const Send = struct {
    pub const name = "mail.send";
    /// A plugin's alone: not listed among the commands people and agents run.
    pub const plugins_only = true;
    /// Never written to the logs.
    pub const secret = .{"password"};
    pub const description = "Hand an email to an SMTP server, as the calling plugin";
    pub const details =
        \\Answers whether the server took it and its answer (`250 2.0.0 Ok: queued as 4F3A`),
        \\or why not in words: what the server said, TLS failing, no answer in 30 seconds.
        \\Refused outside queued work (a job, an `on` hook), unless the caller is a plugin
        \\granted `mail.send`, in production for a local or private address or `none`
        \\security, and when a `{secret:NAME}` it names is not declared in its `.secrets` or
        \\has no value ("<label> isn't set"). The message goes as written: headers, a blank
        \\line, the body; core ends its lines in CRLF and doubles a leading dot. Logged under
        \\the run: server, port, recipients' count, the answer, time; never the message or
        \\the credentials.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        host: []const u8,
        port: u16 = 587,
        security: smtp.Security = .starttls,
        user: []const u8 = "",
        password: []const u8 = "",
        from: []const u8,
        to: []const []const u8,
        message: []const u8,
    };
    pub const Out = struct {
        sent: bool,
        reply: []const u8,
    };
    pub const example: In = .{
        .host = "smtp.example.com",
        .user = "shop@example.com",
        .password = "{secret:SMTP_PASSWORD}",
        .from = "shop@example.com",
        .to = &.{"ada@example.com"},
        .message = "From: Shop <shop@example.com>\r\nTo: ada@example.com\r\n" ++
            "Subject: Your order\r\n\r\nThank you.\r\n",
    };
    pub const example_out: Out = .{
        .sent = true,
        .reply = "250 2.0.0 Ok: queued as 4F3A",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .host = "The SMTP server's name: smtp.example.com",
        .port = "587 for STARTTLS, 465 for TLS, 25 for none",
        .security = "starttls, tls, or none (development only)",
        .user = "Signs in when given; may hold {secret:NAME}",
        .password = "May hold {secret:NAME}",
        .from = "The envelope's sender: shop@example.com",
        .to = "The envelope's recipients, 1 to 50",
        .message = "The email as written (RFC 5322), up to 8 MiB",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .sent = "Whether the server took it",
        .reply = "The server's answer to the message, or why it was not sent",
    };

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
