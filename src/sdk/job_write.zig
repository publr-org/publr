//! A queued run's write: a job or an `on` hook run is one transaction, as an operation is.
//! What it changes and the events it emits (`ctx.emit`) commit together when it ends well,
//! and roll back together when it fails. An outside call never waits inside a write: before
//! one (`http.fetch`, a stream, a download, a mail sent), what the run wrote so far commits,
//! and a new write starts, so the site's other writes never wait on another server. A run
//! that failed for the last time has its writes undone, and its `on_failure` writes kept.
const std = @import("std");
const db = @import("../lib/db.zig");
const context = @import("context.zig");
const Error = @import("operation.zig").Error;

const Ctx = context.Ctx;

pub const JobWrite = struct {
    transaction: db.Transaction,
    /// Where the run's events go: the SDK's own hand, as an operation's.
    notify: context.Notify,
    parent: ?context.OperationId,
    notify_before: ?context.Notify,
    refusal_before: ?Error,
    /// The run failed and its writes were undone; what follows (`on_failure`) is kept.
    failed: bool = false,

    /// Starts the run's write; `ctx.job_write` points at it until `close`.
    pub fn open(ctx: *Ctx, notify: context.Notify) Error!JobWrite {
        std.debug.assert(ctx.db.transaction_depth == 0);
        std.debug.assert(ctx.job_write == null);

        const write: JobWrite = .{
            .transaction = try ctx.db.transaction(),
            .notify = notify,
            .parent = ctx.parent,
            .notify_before = ctx.notify,
            .refusal_before = ctx.event_refusal,
        };

        ctx.parent = ctx.allocate_operation_id();
        ctx.notify = notify;
        ctx.event_refusal = null;

        return write;
    }

    /// Before an outside call: what the run wrote so far commits, and a new write starts.
    /// Inside an operation's own write (a write calling out) nothing commits: that
    /// operation's write is not the run's to end.
    pub fn step(write: *JobWrite, ctx: *Ctx) Error!void {
        std.debug.assert(!write.transaction.finished);
        std.debug.assert(ctx.db.transaction_depth >= write.transaction.depth);

        if (ctx.db.transaction_depth != write.transaction.depth) {
            return;
        }

        if (ctx.event_refusal) |refused| {
            return refused;
        }

        try write.transaction.commit();
        write.transaction = try ctx.db.transaction();
    }

    /// The run failed: its writes are undone, and a new write starts for what follows.
    pub fn undo(write: *JobWrite, ctx: *Ctx) Error!void {
        std.debug.assert(!write.transaction.finished);
        std.debug.assert(ctx.db.transaction_depth == write.transaction.depth);

        write.transaction.rollback();
        write.transaction = try ctx.db.transaction();
        write.failed = true;
        ctx.event_refusal = null;
    }

    /// Ends the run's write: kept when it `ran` (or failed and was undone already, keeping
    /// what followed), else rolled back. Answers the refusal of an event it emitted, which
    /// undoes the run as a failure would.
    pub fn close(write: *JobWrite, ctx: *Ctx, ran: bool) ?Error {
        std.debug.assert(ctx.db.transaction_depth == write.transaction.depth);
        std.debug.assert(write.transaction.depth == 1);

        const refused = ctx.event_refusal;

        defer {
            ctx.parent = write.parent;
            ctx.notify = write.notify_before;
            ctx.event_refusal = write.refusal_before;
        }

        if ((ran or write.failed) and refused == null) {
            write.transaction.commit() catch |err| {
                write.transaction.rollback();

                return err;
            };

            return null;
        }

        write.transaction.rollback();

        return refused;
    }
};

/// Before an outside call in queued work: what the run wrote so far commits.
pub fn before_outside_call(ctx: *Ctx) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const write = ctx.job_write orelse return;

    try write.step(ctx);
}
