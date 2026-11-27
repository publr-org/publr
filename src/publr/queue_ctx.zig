//! `publr.QueueCtx`: what queued work (a job, an `on` hook) runs with. Every call
//! `publr.Ctx` has, and `fetch`: queued work alone calls other servers, never code a request
//! waits on. It holds the plugin's `ctx`, compiled in or installed, and hands each call on.
const std = @import("std");
const Ctx = @import("ctx.zig").Ctx;
const words = @import("plugin/words.zig");
const caller_view = @import("caller.zig");
const free_value = @import("free_value.zig");
const operation = @import("operation.zig");
const Error = @import("operation.zig").Error;
const http_operations = @import("operations/http.zig");
const link = @import("operations/link.zig");

pub const QueueCtx = struct {
    /// The plugin's `ctx`: what the SDK's own calls (record handles, queries) take.
    base: *Ctx,

    /// A request to another server, as the plugin: within its `http.fetch` grant and
    /// domains, secrets filled in as it leaves (`{secret:NAME}`).
    pub fn fetch(
        self: *QueueCtx,
        request: http_operations.Fetch.In,
    ) Error!http_operations.Fetch.Out {
        std.debug.assert(request.url.len > 0);
        std.debug.assert(request.method.len > 0);

        return self.base.call(http_operations.Fetch, request);
    }

    pub fn call(
        self: *QueueCtx,
        comptime Operation: type,
        in: Operation.In,
    ) Error!Operation.Out {
        return self.base.call(Operation, in);
    }

    /// An operation by a name known only when it runs: how a contract's provider is
    /// called (`publr.providers`), compiled in or installed.
    pub fn call_named(
        self: *QueueCtx,
        comptime Out: type,
        name: []const u8,
        in: anytype,
    ) Error!Out {
        return self.base.call_named(Out, name, in);
    }

    pub fn call_value(
        self: *QueueCtx,
        name: []const u8,
        input: free_value.Value,
    ) Error!free_value.Value {
        return self.base.call_value(name, input);
    }

    pub fn mod(self: *QueueCtx, comptime name: []const u8, value: anytype) Error!@TypeOf(value) {
        return self.base.mod(name, value);
    }

    pub fn mod_all(
        self: *QueueCtx,
        comptime name: []const u8,
        comptime Value: type,
        values: []const Value,
    ) Error![]const Value {
        return self.base.mod_all(name, Value, values);
    }

    pub fn caller(self: *const QueueCtx) caller_view.View {
        return self.base.caller();
    }

    pub fn sign(
        self: *QueueCtx,
        intent: []const u8,
        subject: []const u8,
        expires: ?words.Time,
    ) Error!link.Sign.Out {
        return self.base.sign(intent, subject, expires);
    }

    pub fn verify(self: *QueueCtx, intent: []const u8, token: []const u8) Error![]const u8 {
        return self.base.verify(intent, token);
    }

    pub fn random(self: *QueueCtx, buffer: []u8) Error!void {
        return self.base.random(buffer);
    }

    pub fn time_zone(self: *QueueCtx) Error!words.TimeZone {
        return self.base.time_zone();
    }

    pub fn now(self: *const QueueCtx) words.Time {
        return self.base.now();
    }

    pub fn grant(self: *const QueueCtx, comptime key: []const u8) Ctx.Grant {
        return self.base.grant(key);
    }

    pub fn alloc(self: *const QueueCtx, comptime Item: type, count: u32) error{OutOfMemory}![]Item {
        return self.base.alloc(Item, count);
    }

    pub fn print(
        self: *const QueueCtx,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        return self.base.print(format, args);
    }

    pub fn arena(self: *const QueueCtx) std.mem.Allocator {
        return self.base.arena();
    }

    /// Memory of its own for one step of the work, given back at its `end()`.
    pub fn scope(self: *QueueCtx) Ctx.Scope {
        return self.base.scope();
    }

    pub fn t(self: *const QueueCtx, comptime text: []const u8, values: anytype) []const u8 {
        return self.base.t(text, values);
    }

    pub fn tn(
        self: *const QueueCtx,
        comptime one: []const u8,
        comptime many: []const u8,
        count: u64,
        values: anytype,
    ) []const u8 {
        return self.base.tn(one, many, count, values);
    }

    pub fn translate(self: *const QueueCtx, text: []const u8) []const u8 {
        return self.base.translate(text);
    }

    pub fn language(self: *const QueueCtx) []const u8 {
        return self.base.language();
    }

    pub fn locale(self: *const QueueCtx, person: []const u8) Ctx.Locale {
        return self.base.locale(person);
    }

    pub fn emit(self: *QueueCtx, comptime Event: type, payload: Event.Payload) void {
        self.base.emit(Event, payload);
    }

    pub fn fail(
        self: *QueueCtx,
        comptime name: @TypeOf(.enum_literal),
        comptime text: []const u8,
        values: anytype,
    ) error{Failed} {
        return self.base.fail(name, text, values);
    }

    pub fn refuse(
        self: *QueueCtx,
        problems: []const operation.Problem,
    ) error{ Invalid, OutOfMemory } {
        return self.base.refuse(problems);
    }

    /// The declared refusal (`Fails:` name) the last call or the job's own `fail`
    /// ended with; empty when none: what `.on_failure` reads beside the error.
    pub fn failure(self: *const QueueCtx) []const u8 {
        return self.base.failure();
    }

    pub fn log(
        self: *QueueCtx,
        comptime level: words.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        self.base.log(level, format, args);
    }

    pub fn enqueue(self: *QueueCtx, comptime Job: type, in: Job.Input) Error!void {
        return self.base.enqueue(Job, in);
    }

    pub fn enqueue_at(
        self: *QueueCtx,
        comptime Job: type,
        in: Job.Input,
        at: words.Time,
    ) Error!void {
        return self.base.enqueue_at(Job, in, at);
    }
};
