//! The plugin SDK inside the sandbox: `SandboxApi`, the same calls a native plugin makes, with
//! every call proxied to the host as JSON, and the exports the host drives the plugin with.
//! A plugin never writes `export fn`: `Exports(Plugin)` generates them from its declarations.
const std = @import("std");
const mods = @import("../mods.zig");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const json = @import("../../lib/json.zig");
const Caller = @import("../caller.zig").Caller;
const Grant = @import("../grant.zig").Grant;
const contract = @import("../plugin.zig");
const plugin_manifest = @import("manifest.zig");
const runtime = @import("sandboxed.zig");
const filter_reads = @import("filter_reads.zig");
const queue = @import("queue.zig");
const job_define = @import("job_define.zig");
const words = @import("words.zig");
const permission_define = @import("permission_define.zig");
const permission = @import("../../model/permission.zig");
const caller_view = @import("caller_view.zig");
const operation_contract = @import("../operation.zig");

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
extern "env" fn publr_emit(
    name_ptr: [*]const u8,
    name_len: u32,
    payload_ptr: [*]const u8,
    payload_len: u32,
) void;
extern "env" fn publr_granted(key_ptr: [*]const u8, key_len: u32) u32;
extern "env" fn publr_grant_domains(key_ptr: [*]const u8, key_len: u32, result: *wire.Result) u32;
extern "env" fn publr_enqueue(ptr: [*]const u8, len: u32) u32;
extern "env" fn publr_log_at(level: u32, ptr: [*]const u8, len: u32) void;
extern "env" fn publr_problem(
    field_ptr: [*]const u8,
    field_len: u32,
    message_ptr: [*]const u8,
    message_len: u32,
) void;
extern "env" fn publr_refuse(
    name_ptr: [*]const u8,
    name_len: u32,
    message_ptr: [*]const u8,
    message_len: u32,
    status: u32,
) void;

const parse_options: std.json.ParseOptions = .{
    .ignore_unknown_fields = true,
    .allocate = .alloc_always,
};

/// What a sandboxed plugin reaches Publr through: every call a JSON message to the host.
pub const SandboxApi = struct {
    arena_allocator: std.mem.Allocator,
    now_at_ms: i64,
    name: []const u8,
    on_behalf_of: ?[]const u8,
    visitor_id: []const u8 = "",
    /// Who is calling, as the host sees it.
    facts: wire.Caller = .{},
    /// The `Fails:` of the operation running, for the status of a refusal.
    failures: []const operation_contract.Failure = &.{},
    /// Set while a filter runs: its reads are noted and answered for the whole batch.
    reads: ?*filter_reads.Reads = null,

    /// The plugin itself, acting for the account that made the call when there is one.
    pub fn caller(self: *const SandboxApi) caller_view.View {
        std.debug.assert(self.now_at_ms >= 0);
        std.debug.assert(self.name.len > 0);

        const person = self.on_behalf_of orelse "";
        const raw: Caller = if (self.facts.signed_in and person.len > 0) .{
            .user = .{
                .id = person,
                .roles = self.facts.roles,
            },
        } else .{
            .plugin = .{
                .name = self.name,
                .capabilities = &.{},
                .on_behalf_of = self.on_behalf_of,
            },
        };

        return .{
            .from = caller_view.joined(self.facts.from, self.facts.plugin),
            .visitor = self.visitor_id,
            .referer = self.facts.referer,
            .raw = raw,
            .granted_here = self.facts.granted,
        };
    }

    /// Queues `Job` to run after this call, as the plugin; inside a write, a rolled-back
    /// write queues nothing.
    pub fn enqueue(self: *SandboxApi, comptime Job: type, in: Job.Input) Error!void {
        std.debug.assert(self.now_at_ms >= 0);
        comptime std.debug.assert(job_define.is_job(Job));

        return self.enqueue_at(Job, in, self.now());
    }

    /// `enqueue` with when it may run: never before `at`.
    pub fn enqueue_at(
        self: *SandboxApi,
        comptime Job: type,
        in: Job.Input,
        at: words.Time,
    ) Error!void {
        comptime std.debug.assert(job_define.is_job(Job));
        std.debug.assert(self.name.len > 0);

        if (comptime Job.every != null) {
            @compileError("a repeating job runs on its own; it is never queued");
        }

        const text = std.json.Stringify.valueAlloc(self.arena_allocator, .{
            .name = Job.verb,
            .in = in,
            .due_ms = at.ms,
        }, .{}) catch return error.OutOfMemory;
        const code = publr_enqueue(text.ptr, @intCast(text.len));

        if (code != wire.ok) {
            return wire.error_of(code);
        }
    }

    /// What the administrator granted for a request: whether the key is on, and its flags.
    pub fn grant(self: *const SandboxApi, comptime key: []const u8) permission_define.Grant {
        std.debug.assert(self.name.len > 0);

        comptime std.debug.assert(permission.find(&permission.core, key) != null);

        var granted = permission_define.Grant.from_bits(publr_granted(key.ptr, key.len) & 0x1f);

        if (comptime std.mem.eql(u8, key, "http.fetch")) {
            if (granted.on) {
                granted.domains = self.granted_domains(key);
            }
        }

        return granted;
    }

    /// The domains granted on `key` now, in the call's arena; none when they can't be read.
    fn granted_domains(self: *const SandboxApi, comptime key: []const u8) []const []const u8 {
        std.debug.assert(self.name.len > 0);

        var result: wire.Result = .{
            .ptr = 0,
            .len = 0,
        };

        if (publr_grant_domains(key.ptr, key.len, &result) != wire.ok) {
            return &.{};
        }

        const text = take(result);
        defer if (text.len > 0) allocator.free(text);

        var domains: std.ArrayList([]const u8) = .empty;
        var lines = std.mem.splitScalar(u8, text, '\n');

        while (lines.next()) |line| {
            if (line.len == 0) {
                continue;
            }

            const copy = self.arena_allocator.dupe(u8, line) catch return &.{};

            domains.append(self.arena_allocator, copy) catch return &.{};
        }

        return domains.items;
    }

    pub fn now(self: *const SandboxApi) words.Time {
        std.debug.assert(self.now_at_ms >= 0);
        std.debug.assert(self.name.len > 0);

        return .{
            .ms = self.now_at_ms,
        };
    }

    pub fn alloc(
        self: *const SandboxApi,
        comptime Item: type,
        count: u32,
    ) error{OutOfMemory}![]Item {
        std.debug.assert(count <= 1 << 24);

        return self.arena_allocator.alloc(Item, count);
    }

    pub fn print(
        self: *const SandboxApi,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        comptime std.debug.assert(format.len > 0);

        return std.fmt.allocPrint(self.arena_allocator, format, args);
    }

    /// Text for people, each `{name}` filled from `values`. Installed plugins' catalogues
    /// reach the host with the package's files; until then the source text.
    pub fn t(self: *const SandboxApi, comptime text: []const u8, values: anytype) []const u8 {
        comptime std.debug.assert(text.len > 0);

        return words.filled(self.arena_allocator, text, values) catch text;
    }

    pub fn tn(
        self: *const SandboxApi,
        comptime one: []const u8,
        comptime many: []const u8,
        count: u64,
        values: anytype,
    ) []const u8 {
        comptime std.debug.assert(one.len > 0 and many.len > 0);

        if (count == 1) {
            return words.filled(self.arena_allocator, one, values) catch one;
        }

        return words.filled(self.arena_allocator, many, values) catch many;
    }

    pub fn arena(self: *const SandboxApi) std.mem.Allocator {
        std.debug.assert(self.now_at_ms >= 0);
        std.debug.assert(self.name.len > 0);

        return self.arena_allocator;
    }

    /// Passes `value` through every modifier of `name` (`publr.modify(name, …)` in any
    /// plugin) and answers what they made of it; with none, the value as it went.
    pub fn mod(self: *SandboxApi, comptime name: []const u8, value: anytype) Error!@TypeOf(value) {
        const changed = try self.mod_all(name, @TypeOf(value), &.{value});

        std.debug.assert(changed.len == 1);

        return changed[0];
    }

    /// `mod` for several values at once: a modifier's reads are made together for all.
    pub fn mod_all(
        self: *SandboxApi,
        comptime name: []const u8,
        comptime Value: type,
        values: []const Value,
    ) Error![]const Value {
        comptime {
            if (!mods.valid(name, false)) {
                @compileError("`" ++ name ++ "` is no mod name: dotted parts of a-z, 0-9 and _");
            }
        }

        std.debug.assert(values.len <= mods.items_max);

        const memory = self.arena();
        const text = std.json.Stringify.valueAlloc(memory, values, .{}) catch {
            return error.OutOfMemory;
        };
        const answered = try self.call(mods.Apply, .{
            .name = name,
            .values = text,
        });

        return std.json.parseFromSliceLeaky([]const Value, memory, answered.values, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch values;
    }

    /// Runs `Operation` in the host as this plugin, with its grants: `error.Denied` when an
    /// administrator has not granted (or has revoked) what it needs.
    pub fn call(self: *SandboxApi, comptime Operation: type, in: Operation.In) Error!Operation.Out {
        const own = comptime @hasDecl(Operation, "publr_operation_definition");

        if (comptime !own) {
            comptime runtime.check_call(Operation.name);
        }

        std.debug.assert(self.name.len > 0);

        // One of the plugin's own operations, by its definition: named under the plugin.
        const operation_name = if (own)
            std.fmt.allocPrint(self.arena_allocator, "{s}.{s}", .{
                self.name,
                Operation.verb,
            }) catch return error.OutOfMemory
        else
            Operation.name;

        if (self.reads) |reads| {
            return reads.answer(Operation.Out, operation_name, in);
        }

        const input = std.json.Stringify.valueAlloc(self.arena_allocator, in, .{}) catch {
            return error.OutOfMemory;
        };
        const output = try self.call_json(operation_name, input);

        return json.parse(Operation.Out, self.arena_allocator, output, parse_options) catch {
            return error.Invalid;
        };
    }

    /// Calls an operation in the host by name, JSON in and out, as this plugin.
    pub fn call_json(self: *SandboxApi, name: []const u8, input: []const u8) Error![]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.reads == null);

        var result: wire.Result = .{
            .ptr = 0,
            .len = 0,
        };
        const status = publr_call(name.ptr, name.len, input.ptr, @intCast(input.len), &result);

        if (status != wire.ok) {
            return wire.error_of(status);
        }

        const output = take(result);
        defer allocator.free(output);

        return self.arena_allocator.dupe(u8, output) catch error.OutOfMemory;
    }

    /// Emits an event made with `publr.event.define`, its payload as JSON: the host runs its
    /// `after` hooks inside the write and queues it for the `on` hooks.
    pub fn emit(self: *SandboxApi, comptime Event: type, payload: Event.Payload) void {
        std.debug.assert(self.name.len > 0);
        comptime std.debug.assert(@hasDecl(Event, "publr_event_definition"));

        const name = if (comptime Event.full_name.len > 0)
            Event.full_name
        else
            std.fmt.allocPrint(self.arena_allocator, "{s}.{s}", .{ self.name, Event.verb }) catch
                return;
        const arena_memory = self.arena_allocator;
        const text = std.json.Stringify.valueAlloc(arena_memory, payload, .{}) catch return;

        publr_emit(name.ptr, @intCast(name.len), text.ptr, @intCast(text.len));
    }

    /// A line in the host's log, attributed to the plugin.
    /// Refuses the call in the plugin's own words: `return ctx.fail("NotEnoughStock", "Only 2
    /// left")`. The name is what a form's redirect carries (`?error=NotEnoughStock`), the
    /// message what a person reads. The write rolls back like any other error's.
    pub fn fail(
        self: *SandboxApi,
        comptime name: @TypeOf(.enum_literal),
        comptime text: []const u8,
        values: anytype,
    ) error{Failed} {
        std.debug.assert(self.name.len > 0);
        comptime std.debug.assert(@tagName(name).len > 0);

        const tag = @tagName(name);
        const message = words.kept(self.t(text, values));
        const status = words.status_of(self.failures, tag);

        publr_refuse(tag.ptr, @intCast(tag.len), message.ptr, @intCast(message.len), status);

        return error.Failed;
    }

    /// Refuses the input with every problem `.validate` found, each beside its field: the
    /// host keeps them one by one, then the call ends `Invalid`.
    pub fn refuse(
        self: *SandboxApi,
        problems: []const operation_contract.Problem,
    ) error{ Invalid, OutOfMemory } {
        std.debug.assert(self.name.len > 0);
        std.debug.assert(problems.len > 0);

        for (problems) |problem| {
            const field = problem.field;
            const message = problem.message;

            publr_problem(field.ptr, @intCast(field.len), message.ptr, @intCast(message.len));
        }

        return error.Invalid;
    }

    pub fn log(
        self: *SandboxApi,
        comptime level: words.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        std.debug.assert(self.name.len > 0);
        comptime std.debug.assert(format.len > 0);

        const line = std.fmt.allocPrint(self.arena_allocator, format, args) catch format;

        publr_log_at(@intFromEnum(level), line.ptr, @intCast(line.len));
    }
};

pub fn take(result: wire.Result) []u8 {
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

        @export(&Generated.alloc, .{
            .name = "publr_alloc",
        });
        @export(&Generated.free, .{
            .name = "publr_free",
        });
        @export(&Generated.invoke, .{
            .name = "publr_invoke",
        });
        @export(&Generated.manifest, .{
            .name = "publr_manifest",
        });
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

            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();

            plugin_manifest.write(Plugin, arena_state.allocator(), &output.writer) catch {
                return wire.code_of(error.OutOfMemory);
            };

            const bytes = output.toOwnedSlice() catch return wire.code_of(error.OutOfMemory);

            std.debug.assert(bytes.len > 0);
            result.* = .{
                .ptr = @intCast(@intFromPtr(bytes.ptr)),
                .len = @intCast(bytes.len),
            };

            return wire.ok;
        }

        pub fn invoke(entry: u32, in_ptr: u32, in_len: u32, result_ptr: u32) callconv(.c) u32 {
            std.debug.assert(result_ptr != 0);
            std.debug.assert(in_ptr != 0 or in_len == 0);

            const result: *wire.Result = @ptrFromInt(result_ptr);
            var arena_state = std.heap.ArenaAllocator.init(allocator);
            defer arena_state.deinit();

            result.* = .{
                .ptr = 0,
                .len = 0,
            };

            const input = take(.{
                .ptr = in_ptr,
                .len = in_len,
            });

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
                .before, .modify => run_before(item.declaration, input, result, arena),
                .after => run_after(item.declaration, input, arena),
                .event => run_event(item.declaration, input, arena),
                .job => run_job(item.declaration, input, arena),
            };
        }

        fn context(arena: std.mem.Allocator, envelope: anytype) SandboxApi {
            std.debug.assert(envelope.now_ms >= 0);
            std.debug.assert(envelope.on_behalf_of == null or envelope.on_behalf_of.?.len > 0);

            return .{
                .arena_allocator = arena,
                .now_at_ms = envelope.now_ms,
                .name = Plugin.manifest.name,
                .on_behalf_of = envelope.on_behalf_of,
                .visitor_id = envelope.visitor,
                .facts = envelope.caller,
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
            var ctx = context(arena, envelope);

            ctx.failures = comptime words.failures_of(Operation);

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
            var ctx = context(arena, envelope);
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
            var ctx = context(arena, envelope);
            var in = envelope.in;

            try Middleware.run(&ctx, &in, &envelope.out);
        }

        fn run_event(
            comptime Middleware: type,
            input: []const u8,
            arena: std.mem.Allocator,
        ) Error!void {
            // The event's payload, or the operation's answer, read into the hook's type.
            const Shape = wire.Envelope(Middleware.Payload);
            const envelope = json.parse(Shape, arena, input, parse_options) catch {
                return error.Invalid;
            };
            var ctx = context(arena, envelope);

            return Middleware.run(&ctx, envelope.in);
        }

        /// A queued job: its input, and whether this is its last attempt, when `.on_failure`
        /// hears why it failed.
        fn run_job(comptime Job: type, input: []const u8, arena: std.mem.Allocator) Error!void {
            comptime std.debug.assert(job_define.is_job(Job));

            const In = if (Job.Input == void) struct {} else Job.Input;
            const envelope = json.parse(wire.JobEnvelope(In), arena, input, parse_options) catch {
                return error.Invalid;
            };
            var base = context(arena, envelope);
            var ctx: queue.Queue(SandboxApi) = .{
                .base = &base,
            };
            const ran = if (comptime Job.Input == void)
                Job.run(&ctx)
            else
                Job.run(&ctx, envelope.in);

            ran catch |err| {
                // A conflict ends the job: `.on_conflict` hears it now, the host keeps it.
                if (err == error.Conflict and comptime @TypeOf(Job.on_conflict) != @TypeOf(null)) {
                    if (comptime Job.Input == void) {
                        Job.on_conflict(&ctx);
                    } else {
                        Job.on_conflict(&ctx, envelope.in);
                    }

                    return err;
                }

                if (envelope.last and comptime @TypeOf(Job.on_failure) != @TypeOf(null)) {
                    if (comptime Job.Input == void) {
                        Job.on_failure(&ctx, @errorName(err));
                    } else {
                        Job.on_failure(&ctx, envelope.in, @errorName(err));
                    }
                }

                return err;
            };
        }
    };
}

fn reply(value: anytype, result: *wire.Result) Error!void {
    const output = std.json.Stringify.valueAlloc(allocator, value, .{}) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(output.len <= std.math.maxInt(u32));

    result.* = .{
        .ptr = @intCast(@intFromPtr(output.ptr)),
        .len = @intCast(output.len),
    };

    std.debug.assert(result.ptr != 0);
}
