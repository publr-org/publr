//! What one top-level call did, gathered while it runs: the calls it set off inside, the
//! notices they raised, and where it failed. The core's activity and error logs are written
//! from it (`Log`, a seam the registry fills); the SDK only gathers, it stores nothing.

const std = @import("std");
const Ctx = @import("context.zig").Ctx;
const operation = @import("operation.zig");

pub const calls_max: u32 = 1024;
pub const notices_max: u32 = 4096;

pub const Notice = struct { name: []const u8, subject: []const u8 };

/// A finished top-level call, as the log receives it.
pub const Entry = struct {
    operation: []const u8,
    /// The input as JSON, before any masking: the log masks it.
    input: []const u8,
    /// The input fields the operation declares secret.
    secret: []const []const u8,
    calls: []const []const u8,
    notices: []const Notice,
    /// Set for a refused or failed call.
    error_name: []const u8 = "",
    message: []const u8 = "",
    /// The inner operation the failure came from, when it came from one.
    failed_in: []const u8 = "",
};

/// Where finished calls go: `activity` inside a write's transaction just before it commits,
/// `failure` after a refused or rolled-back call, outside any transaction.
pub const Log = struct {
    activity: *const fn (*Ctx, *const Entry) operation.Error!void,
    failure: *const fn (*Ctx, *const Entry) void,
};

pub const Trail = struct {
    /// The top-level call's operation id.
    root: u64,
    calls: std.ArrayList([]const u8) = .empty,
    notices: std.ArrayList(Notice) = .empty,
    failed_in: []const u8 = "",
    message: []const u8 = "",

    /// An inner call finished: kept by name, and the first failure with its message.
    pub fn called(trail: *Trail, ctx: *Ctx, name: []const u8, failed: bool) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(trail.root != 0);

        if (trail.calls.items.len < calls_max) {
            trail.calls.append(ctx.arena, name) catch return;
        }

        if (failed and trail.failed_in.len == 0) {
            trail.failed_in = name;
            trail.message = if (ctx.failure) |failure| failure.message else "";
        }
    }

    pub fn noticed(trail: *Trail, ctx: *Ctx, notice: Notice) void {
        std.debug.assert(notice.name.len > 0);
        std.debug.assert(trail.root != 0);

        if (trail.notices.items.len < notices_max) {
            trail.notices.append(ctx.arena, notice) catch return;
        }
    }

    pub fn entry(
        trail: *const Trail,
        name: []const u8,
        input: []const u8,
        secret: []const []const u8,
    ) Entry {
        std.debug.assert(name.len > 0);
        std.debug.assert(trail.root != 0);

        return .{
            .operation = name,
            .input = input,
            .secret = secret,
            .calls = trail.calls.items,
            .notices = trail.notices.items,
            .failed_in = trail.failed_in,
            .message = trail.message,
        };
    }
};

/// The input fields an operation declares secret: `pub const secret = .{"password"}`.
pub fn secret_of(comptime Operation: type) []const []const u8 {
    comptime {
        if (!@hasDecl(Operation, "secret")) {
            return &.{};
        }

        var names: [Operation.secret.len][]const u8 = undefined;

        for (Operation.secret, 0..) |field, index| {
            std.debug.assert(@hasField(Operation.In, field));
            names[index] = field;
        }

        const kept = names;

        return &kept;
    }
}
