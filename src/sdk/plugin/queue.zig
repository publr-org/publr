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

        pub fn call_json(
            self: *Self,
            name: []const u8,
            input: []const u8,
        ) @TypeOf(Base.call_json(@as(*Base, undefined), "", "")) {
            return self.base.call_json(name, input);
        }

        pub fn mod(
            self: *Self,
            comptime name: []const u8,
            value: anytype,
        ) @TypeOf(Base.mod(@as(*Base, undefined), name, value)) {
            return self.base.mod(name, value);
        }

        pub fn caller(self: *const Self) @TypeOf(Base.caller(@as(*const Base, undefined))) {
            return self.base.caller();
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
