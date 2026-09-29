//! The plugin SDK inside the sandbox: `SandboxApi`, the same calls a native plugin makes, with
//! every call proxied to the host as JSON, and the exports the host drives the plugin with.
//! A plugin never writes `export fn`: `Exports(Plugin)` generates them from its declarations.
const std = @import("std");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const json = @import("../../lib/json.zig");
const Caller = @import("../caller.zig").Caller;
const Grant = @import("../grant.zig").Grant;
const middleware = @import("../middleware.zig");
const contract = @import("../plugin.zig");
const plugin_manifest = @import("manifest.zig");
const runtime = @import("sandboxed.zig");

pub const Error = wire.Error;

/// How this build of a plugin is loaded: `sandboxed`, a Wasm module the host runs, or
/// `native`, compiled into Publr.
pub const mode: Mode = if (builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding)
    .sandboxed
else
    .native;

pub const Mode = enum { native, sandboxed };

const allocator = std.heap.wasm_allocator;

extern "env" fn publr_call(
    name_ptr: [*]const u8,
    name_len: u32,
    in_ptr: [*]const u8,
    in_len: u32,
    result: *wire.Result,
) u32;
extern "env" fn publr_notice(
    name_ptr: [*]const u8,
    name_len: u32,
    subject_ptr: [*]const u8,
    subject_len: u32,
) void;
extern "env" fn publr_log(ptr: [*]const u8, len: u32) void;

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

/// What a sandboxed plugin reaches Publr through: every call a JSON message to the host.
pub const SandboxApi = struct {
    arena_allocator: std.mem.Allocator,
    now: i64,
    name: []const u8,
    on_behalf_of: ?[]const u8,

    /// The plugin itself, acting for the account that made the call when there is one.
    pub fn caller(self: *const SandboxApi) Caller {
        std.debug.assert(self.now >= 0);
        std.debug.assert(self.name.len > 0);

        return .{ .plugin = .{
            .name = self.name,
            .capabilities = &.{},
            .on_behalf_of = self.on_behalf_of,
        } };
    }

    pub fn now_ms(self: *const SandboxApi) i64 {
        std.debug.assert(self.now >= 0);
        std.debug.assert(self.name.len > 0);

        return self.now;
    }

    pub fn arena(self: *const SandboxApi) std.mem.Allocator {
        std.debug.assert(self.now >= 0);
        std.debug.assert(self.name.len > 0);

        return self.arena_allocator;
    }

    /// Runs `Operation` in the host as this plugin, with its grants: `error.Denied` when an
    /// administrator has not granted (or has revoked) what it needs.
    pub fn call(self: *SandboxApi, comptime Operation: type, in: Operation.In) Error!Operation.Out {
        comptime runtime.check_call(Operation.name);
        std.debug.assert(Operation.name.len > 0);
        std.debug.assert(self.name.len > 0);

        const input = std.json.Stringify.valueAlloc(self.arena_allocator, in, .{}) catch {
            return error.OutOfMemory;
        };
        var result: wire.Result = .{ .ptr = 0, .len = 0 };
        const status = publr_call(
            Operation.name.ptr,
            Operation.name.len,
            input.ptr,
            @intCast(input.len),
            &result,
        );

        if (status != wire.ok) {
            return wire.error_of(status);
        }

        const output = take(result);
        defer allocator.free(output);

        return json.parse(Operation.Out, self.arena_allocator, output, parse_options) catch {
            return error.Invalid;
        };
    }

    pub fn notice(self: *SandboxApi, name: []const u8, subject: []const u8) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.name.len > 0);

        publr_notice(name.ptr, @intCast(name.len), subject.ptr, @intCast(subject.len));
    }

    /// A line in the host's log, attributed to the plugin.
    pub fn log(self: *SandboxApi, line: []const u8) void {
        std.debug.assert(self.name.len > 0);
        std.debug.assert(line.len > 0);

        publr_log(line.ptr, @intCast(line.len));
    }
};

fn take(result: wire.Result) []u8 {
    std.debug.assert(result.ptr != 0 or result.len == 0);

    if (result.len == 0) {
        return &.{};
    }

    const start: [*]u8 = @ptrFromInt(result.ptr);

    return start[0..result.len];
}

/// Exports the module's entry points; the build calls it from the module's root.
pub fn export_all(comptime Plugin: type) void {
    comptime {
        std.debug.assert(mode == .sandboxed);
        std.debug.assert(Plugin.manifest.name.len > 0);

        const Generated = Exports(Plugin);

        @export(&Generated.alloc, .{ .name = "publr_alloc" });
        @export(&Generated.free, .{ .name = "publr_free" });
        @export(&Generated.invoke, .{ .name = "publr_invoke" });
        @export(&Generated.manifest, .{ .name = "publr_manifest" });
    }
}

/// The exports a plugin's module gives the host: memory for the host to write into, and one
/// entry point for every operation and hook, numbered in manifest order.
pub fn Exports(comptime Plugin: type) type {
    const entries = contract.runtime_entries(Plugin);

    return struct {
        pub fn alloc(len: u32) callconv(.c) u32 {
            const bytes = allocator.alloc(u8, @max(len, 1)) catch return 0;

            return @intCast(@intFromPtr(bytes.ptr));
        }

        pub fn free(ptr: u32, len: u32) callconv(.c) void {
            std.debug.assert(len < 1 << 30);

            if (ptr == 0) {
                return;
            }

            const start: [*]u8 = @ptrFromInt(ptr);

            allocator.free(start[0..@max(len, 1)]);
        }

        /// The plugin's manifest as JSON, for building it into the module's `publr` section:
        /// read by running the module, since only a native build could print it otherwise.
        /// The host frees it with `publr_free`.
        pub fn manifest(result_ptr: u32) callconv(.c) u32 {
            std.debug.assert(result_ptr != 0);

            const result: *wire.Result = @ptrFromInt(result_ptr);
            var output: std.Io.Writer.Allocating = .init(allocator);

            plugin_manifest.write(Plugin, &output.writer) catch {
                return wire.code_of(error.OutOfMemory);
            };

            const bytes = output.toOwnedSlice() catch return wire.code_of(error.OutOfMemory);

            std.debug.assert(bytes.len > 0);
            result.* = .{ .ptr = @intCast(@intFromPtr(bytes.ptr)), .len = @intCast(bytes.len) };

            return wire.ok;
        }

        pub fn invoke(entry: u32, in_ptr: u32, in_len: u32, result_ptr: u32) callconv(.c) u32 {
            std.debug.assert(result_ptr != 0);
            std.debug.assert(in_ptr != 0 or in_len == 0);

            const result: *wire.Result = @ptrFromInt(result_ptr);
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();

            result.* = .{ .ptr = 0, .len = 0 };

            const input = take(.{ .ptr = in_ptr, .len = in_len });

            inline for (entries, 0..) |item, index| {
                if (entry == index) {
                    run(item, input, result, arena_state.allocator()) catch |err| {
                        return wire.code_of(err);
                    };

                    return wire.ok;
                }
            }

            return wire.code_of(error.NotFound);
        }

        fn run(
            comptime item: contract.Entry,
            input: []const u8,
            result: *wire.Result,
            arena: std.mem.Allocator,
        ) Error!void {
            return switch (item.stage) {
                .operation => run_operation(item.declaration, input, result, arena),
                .before => run_before(item.declaration, input, result, arena),
                .after => run_after(item.declaration, input, arena),
                .event => run_event(item.declaration, input, arena),
            };
        }

        fn context(arena: std.mem.Allocator, now: i64, on_behalf_of: ?[]const u8) SandboxApi {
            std.debug.assert(now >= 0);
            std.debug.assert(on_behalf_of == null or on_behalf_of.?.len > 0);

            return .{
                .arena_allocator = arena,
                .now = now,
                .name = Plugin.manifest.name,
                .on_behalf_of = on_behalf_of,
            };
        }

        fn run_operation(
            comptime Operation: type,
            input: []const u8,
            result: *wire.Result,
            arena: std.mem.Allocator,
        ) Error!void {
            const Shape = wire.Envelope(Operation.In);
            const envelope = json.parse(Shape, arena, input, parse_options) catch {
                return error.Invalid;
            };
            var ctx = context(arena, envelope.now_ms, envelope.on_behalf_of);
            const out = try Operation.run(&ctx, envelope.in, &Grant.allow_all);

            try reply(out, result);
        }

        fn run_before(
            comptime Middleware: type,
            input: []const u8,
            result: *wire.Result,
            arena: std.mem.Allocator,
        ) Error!void {
            const In = contract.HookIn(Middleware);
            const envelope = json.parse(wire.Envelope(In), arena, input, parse_options) catch {
                return error.Invalid;
            };
            var ctx = context(arena, envelope.now_ms, envelope.on_behalf_of);
            var in = envelope.in;

            try Middleware.run(&ctx, &in);
            try reply(in, result);
        }

        fn run_after(
            comptime Middleware: type,
            input: []const u8,
            arena: std.mem.Allocator,
        ) Error!void {
            const In = contract.HookIn(Middleware);
            const Shape = wire.AfterEnvelope(In, contract.HookOut(Middleware));
            const envelope = json.parse(Shape, arena, input, parse_options) catch {
                return error.Invalid;
            };
            var ctx = context(arena, envelope.now_ms, envelope.on_behalf_of);
            var in = envelope.in;

            try Middleware.run(&ctx, &in, &envelope.out);
        }

        fn run_event(
            comptime Middleware: type,
            input: []const u8,
            arena: std.mem.Allocator,
        ) Error!void {
            const Shape = wire.Envelope(wire.Event);
            const envelope = json.parse(Shape, arena, input, parse_options) catch {
                return error.Invalid;
            };
            var ctx = context(arena, envelope.now_ms, envelope.on_behalf_of);

            Middleware.run(&ctx, as_event(envelope.in));
        }
    };
}

fn reply(value: anytype, result: *wire.Result) Error!void {
    const output = std.json.Stringify.valueAlloc(allocator, value, .{}) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(output.len <= std.math.maxInt(u32));

    result.* = .{ .ptr = @intCast(@intFromPtr(output.ptr)), .len = @intCast(output.len) };

    std.debug.assert(result.ptr != 0);
}

fn as_event(event: wire.Event) middleware.Event {
    std.debug.assert(event.name.len > 0);

    const failed: middleware.Event.Failed = .{
        .operation_name = event.name,
        .operation_id = 1,
        .err = error_named(event.err),
    };

    return switch (event.kind) {
        .completed => .{ .completed = .{
            .operation_name = event.name,
            .operation_id = 1,
            .duration_ns = 0,
        } },
        .rejected => .{ .rejected = failed },
        .failed => .{ .failed = failed },
        .notice => .{ .notice = .{
            .operation_id = 1,
            .name = event.name,
            .subject = event.subject,
        } },
    };
}

fn error_named(name: []const u8) Error {
    std.debug.assert(name.len <= 64);

    inline for (@typeInfo(Error).error_set.?) |item| {
        if (std.mem.eql(u8, name, item.name)) {
            return @field(Error, item.name);
        }
    }

    return error.Invalid;
}
