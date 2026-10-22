//! Asks a supplier for prices, with its API key.
//!
//! A plugin only ever installed that declares a secret, SUPPLIER_API_KEY, and sends it from
//! a queued job as `{secret:SUPPLIER_API_KEY}`: an administrator can leave it empty when
//! enabling it, fill it later on its page, and watch its job's request carry it. Each
//! request, or why it was refused, shows on its Log tab.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "supplier",
    .version = "0.1.0",
};

pub const AskIn = struct {
    /// The address to send a GET to
    url: []const u8,
    /// The Authorization header it sends; a secret goes in as {secret:NAME}
    authorization: []const u8 = "Bearer {secret:SUPPLIER_API_KEY}",
};

pub const AskOut = struct {
    /// Whether the job was queued
    queued: bool,
};

/// Queues a GET of an address with the supplier's key, sent by a job.
///
/// Example:
///   in: { "url": "https://api.supplier.example/prices" }
///   out: { "queued": true }
pub const Ask = publr.operation.define(AskIn, AskOut, .{
    .name = "ask",
    .kind = .write,
    .run = ask,
});

fn ask(ctx: *publr.Ctx, in: AskIn) publr.Error!AskOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.url.len == 0 or in.url.len > 2048 or in.authorization.len > 512) {
        return error.Invalid;
    }

    try ctx.enqueue(Send, in);

    return .{
        .queued = true,
    };
}

/// Sends the GET with the key; what it answered, or why it did not go, is logged.
pub const Send = publr.job.define(AskIn, .{
    .name = "send",
    .run = send,
});

fn send(ctx: *publr.QueueCtx, in: AskIn) publr.Error!void {
    std.debug.assert(in.url.len > 0);
    std.debug.assert(ctx.now().ms >= 0);

    const answer = ctx.fetch(.{
        .url = in.url,
        .headers = &.{.{
            .name = "Authorization",
            .value = in.authorization,
        }},
    }) catch |err| {
        ctx.log(.warn, "Not sent: {s}", .{@errorName(err)});
        return;
    };

    ctx.log(.info, "Answered: {d}", .{answer.status});
}

/// Secrets this plugin uses; an administrator fills them in.
const Secrets = struct {
    /// Supplier API key
    ///
    /// In the supplier's dashboard under Settings › API › Keys.
    SUPPLIER_API_KEY: publr.Secret,
};

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{Ask},
    .jobs = &.{Send},
    .secrets = Secrets,
    .permissions = &.{.{
        .key = "http.fetch",
        .domains = &.{"api.supplier.example"},
        .reason = "Asks the supplier for prices",
    }},
});
