//! `publr.QueueCtx`: what queued work (a job, an `on` hook) runs with. Every call
//! `publr.Ctx` has, and `fetch`: queued work alone calls other servers, never code a request
//! waits on. It holds the plugin's context, compiled in or installed, and hands each call on.
const std = @import("std");
const http_operations = @import("../../operations/http.zig");
const words = @import("words.zig");

pub fn Queue(comptime Base: type) type {
    return struct {
        base: *Base,

        const Self = @This();

        /// A request to another server, as the plugin: within its `http.fetch` grant and
        /// domains, secrets filled in as it leaves (`{secret:NAME}`).
        pub fn fetch(
            self: *Self,
            request: http_operations.Fetch.In,
        ) @TypeOf(Base.call(@as(*Base, undefined), http_operations.Fetch, request)) {
            std.debug.assert(request.url.len > 0);
            std.debug.assert(request.method.len > 0);

            return self.base.call(http_operations.Fetch, request);
        }

        pub fn call(
            self: *Self,
            comptime Operation: type,
            in: Operation.In,
        ) @TypeOf(Base.call(@as(*Base, undefined), Operation, in)) {
            return self.base.call(Operation, in);
        }

        /// An operation by a name known only when it runs: how a contract's provider is
        /// called (`publr.providers`), compiled in or installed.
        pub fn call_named(
            self: *Self,
            comptime Out: type,
            name: []const u8,
            in: anytype,
        ) @TypeOf(Base.call_named(@as(*Base, undefined), Out, name, in)) {
            return self.base.call_named(Out, name, in);
        }

        pub fn mod(
            self: *Self,
            comptime name: []const u8,
            value: anytype,
        ) @TypeOf(Base.mod(@as(*Base, undefined), name, value)) {
            return self.base.mod(name, value);
        }

        pub fn mod_all(
            self: *Self,
            comptime name: []const u8,
            comptime Value: type,
            values: []const Value,
        ) @TypeOf(Base.mod_all(@as(*Base, undefined), name, Value, values)) {
            return self.base.mod_all(name, Value, values);
        }

        pub fn caller(self: *const Self) @TypeOf(Base.caller(@as(*const Base, undefined))) {
            return self.base.caller();
        }

        pub fn sign(
            self: *Self,
            intent: []const u8,
            subject: []const u8,
            expires: ?words.Time,
        ) @TypeOf(Base.sign(@as(*Base, undefined), "", "", null)) {
            return self.base.sign(intent, subject, expires);
        }

        pub fn verify(
            self: *Self,
            intent: []const u8,
            token: []const u8,
        ) @TypeOf(Base.verify(@as(*Base, undefined), "", "")) {
            return self.base.verify(intent, token);
        }

        pub fn random(
            self: *Self,
            buffer: []u8,
        ) @TypeOf(Base.random(@as(*Base, undefined), buffer)) {
            return self.base.random(buffer);
        }

        pub fn time_zone(
            self: *Self,
        ) @TypeOf(Base.time_zone(@as(*Base, undefined))) {
            return self.base.time_zone();
        }

        pub fn now(self: *const Self) words.Time {
            return self.base.now();
        }

        pub fn grant(
            self: *const Self,
            comptime key: []const u8,
        ) @TypeOf(Base.grant(@as(*const Base, undefined), key)) {
            return self.base.grant(key);
        }

        pub fn alloc(self: *const Self, comptime Item: type, count: u32) error{OutOfMemory}![]Item {
            return self.base.alloc(Item, count);
        }

        pub fn print(
            self: *const Self,
            comptime format: []const u8,
            args: anytype,
        ) error{OutOfMemory}![]const u8 {
            return self.base.print(format, args);
        }

        pub fn arena(self: *const Self) std.mem.Allocator {
            return self.base.arena();
        }

        /// Memory of its own for one step of the work, given back at its `end()`.
        pub fn scope(self: *Self) @TypeOf(Base.scope(@as(*Base, undefined))) {
            return self.base.scope();
        }

        pub fn t(self: *const Self, comptime text: []const u8, values: anytype) []const u8 {
            return self.base.t(text, values);
        }

        pub fn tn(
            self: *const Self,
            comptime one: []const u8,
            comptime many: []const u8,
            count: u64,
            values: anytype,
        ) []const u8 {
            return self.base.tn(one, many, count, values);
        }

        pub fn language(self: *const Self) []const u8 {
            return self.base.language();
        }

        pub fn locale(
            self: *const Self,
            person: []const u8,
        ) @TypeOf(Base.locale(@as(*const Base, undefined), "")) {
            return self.base.locale(person);
        }

        pub fn emit(self: *Self, comptime Event: type, payload: Event.Payload) void {
            self.base.emit(Event, payload);
        }

        pub fn fail(
            self: *Self,
            comptime name: @TypeOf(.enum_literal),
            comptime text: []const u8,
            values: anytype,
        ) error{Failed} {
            return self.base.fail(name, text, values);
        }

        /// The declared refusal (`Fails:` name) the last call or the job's own `fail`
        /// ended with; empty when none: what `.on_failure` reads beside the error.
        pub fn failure(self: *const Self) []const u8 {
            return self.base.failure();
        }

        pub fn log(
            self: *Self,
            comptime level: words.Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            self.base.log(level, format, args);
        }

        pub fn enqueue(
            self: *Self,
            comptime Job: type,
            in: Job.Input,
        ) @TypeOf(Base.enqueue(@as(*Base, undefined), Job, in)) {
            return self.base.enqueue(Job, in);
        }

        pub fn enqueue_at(
            self: *Self,
            comptime Job: type,
            in: Job.Input,
            at: words.Time,
        ) @TypeOf(Base.enqueue_at(@as(*Base, undefined), Job, in, at)) {
            return self.base.enqueue_at(Job, in, at);
        }
    };
}

/// The plugin's context under either: what the SDK's own calls (record handles, queries)
/// take, so they work in a request and in queued work alike.
pub fn base_of(ctx: anytype) BaseOf(@TypeOf(ctx)) {
    if (comptime @hasField(std.meta.Child(@TypeOf(ctx)), "base")) {
        return ctx.base;
    }

    return ctx;
}

fn BaseOf(comptime Pointer: type) type {
    const Child = std.meta.Child(Pointer);

    if (@hasField(Child, "base")) {
        return @FieldType(Child, "base");
    }

    return Pointer;
}
