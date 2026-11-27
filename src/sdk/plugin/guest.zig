//! The plugin SDK inside the sandbox: `SandboxApi`, the same calls a native plugin makes, with
//! every call proxied to the host, its values handed over as they lie (`shape_wire.zig`), and
//! the exports the host drives the plugin with.
//! A plugin never writes `export fn`: `Exports(Plugin)` generates them from its declarations.
const std = @import("std");
const mods = @import("../mods.zig");
const builtin = @import("builtin");
const wire = @import("wire.zig");
const read_memo = @import("read_memo.zig");
const modify_define = @import("../../publr/plugin/modify_define.zig");
const shape_wire = @import("shape_wire.zig");
const shape_parts = @import("shape_parts.zig");
const laid_key = @import("laid_key.zig");
const free_value = @import("../../publr/free_value.zig");
const Caller = @import("../caller.zig").Caller;
const Grant = @import("../grant.zig").Grant;
const contract = @import("../plugin.zig");
const plugin_manifest = @import("manifest.zig");
const plugin_define = @import("bound.zig");
const runtime = @import("sandboxed.zig");
const mod_reads = @import("mod_reads.zig");
const queue = @import("queue.zig");
const job_define = @import("../../publr/plugin/job_define.zig");
const words = @import("../../publr/plugin/words.zig");
const permission_define = @import("permission_define.zig");
const permission = @import("../../model/permission.zig");
const caller_view = @import("caller_view.zig");
const operation_contract = @import("../operation.zig");
const asks = @import("guest_asks.zig");

pub const Error = wire.Error;

const Ctx = @import("../../publr/ctx.zig").Ctx;

/// The installed call behind a plugin's `ctx`: the SDK's own way to the wire.
pub fn api_of(ctx: anytype) ApiOf(@TypeOf(ctx)) {
    comptime std.debug.assert(mode == .sandboxed);

    return @ptrCast(@alignCast(ctx));
}

fn ApiOf(comptime Pointer: type) type {
    return if (@typeInfo(Pointer).pointer.attrs.@"const") *const SandboxApi else *SandboxApi;
}

/// How this build of a plugin is loaded: `sandboxed`, a Wasm module the host runs, or
/// `native`, compiled into Publr.
pub const mode: Mode = if (builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding)
    .sandboxed
else
    .native;

pub const Mode = enum { native, sandboxed };

const guest_memory = @import("guest_memory.zig");
const walks_guest = @import("walks/guest.zig");

const allocator = guest_memory.heap;

extern "env" fn publr_call_shaped(call: *const shape_wire.Call, sizes: *[2]u32) u32;
extern "env" fn publr_call_alone(call: *const shape_wire.Call, sizes: *[2]u32) u32;
extern "env" fn publr_shaped_take(block: u32, table: u32) u32;
extern "env" fn publr_item(index: u32, status: u32) void;
extern "env" fn publr_emit(sent: *const shape_wire.Sent) void;
extern "env" fn publr_undo() void;
extern "env" fn publr_granted(key_ptr: [*]const u8, key_len: u32) u32;
extern "env" fn publr_grant_domains(key_ptr: [*]const u8, key_len: u32, result: *wire.Result) u32;
extern "env" fn publr_enqueue(sent: *const shape_wire.Sent) u32;
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

/// What a sandboxed plugin reaches Publr through: every call a message to the host, its
/// values in the plugin's own structs.
pub const SandboxApi = struct {
    arena_allocator: std.mem.Allocator,
    now_at_ms: i64,
    name: []const u8,
    on_behalf_of: ?[]const u8,
    visitor_id: []const u8 = "",
    /// The language the call speaks, as the host said.
    language_code: []const u8 = "",
    /// Who is calling, as the host sees it.
    facts: wire.Caller = .{},
    /// The `Fails:` of the operation running, for the status of a refusal.
    failures: []const operation_contract.Failure = &.{},
    /// Set while a modifier runs: its reads are noted and answered for the whole batch.
    reads: ?*mod_reads.Reads = null,
    /// The refusal the last call came back with, by name; empty for none.
    last_failure: []const u8 = "",
    /// Set while a read operation runs: the reads it made, answered again without the host.
    memo: ?*read_memo.Memo = null,
    /// What the last refusal says to people; empty for none.
    last_message: []const u8 = "",
    /// Made by `as_plugin`: its calls run as the plugin alone, with no person behind them.
    alone: bool = false,

    pub const as_plugin = asks.as_plugin;
    pub const may = asks.may;
    pub const failure_message = asks.failure_message;
    pub const said_values = asks.said_values;

    /// The plugin's `ctx` this call stands behind.
    pub fn ctx(self: *SandboxApi) *Ctx {
        return @ptrCast(self);
    }

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
                .on_behalf_of = self.on_behalf_of,
            },
        };

        return caller_view.view_of(raw, .{
            .from = caller_view.joined(self.facts.from, self.facts.plugin),
            .visitor = self.visitor_id,
            .referer = self.facts.referer,
            .granted_here = self.facts.granted,
        });
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

        if (comptime Job.every != null or Job.due_on != null) {
            @compileError("a repeating or `.due` job runs on its own; it is never queued");
        }

        // The input goes as it lies: the host writes it down for the queue.
        const Input = if (Job.Input == void) struct {} else Job.Input;
        const input: Input = if (comptime Job.Input == void) .{} else in;
        var parts = try self.sent(Input, Job.verb, &input);

        parts.due_ms = at.ms;

        const code = publr_enqueue(&parts);

        if (code != wire.ok) {
            return wire.error_of(code);
        }
    }

    /// Where `value` and its description are, for the host to read it under `name`.
    fn sent(
        self: *SandboxApi,
        comptime Shape: type,
        name: []const u8,
        value: *const Shape,
    ) Error!shape_wire.Sent {
        const described = comptime shape_wire.describe(Shape);
        var table: std.ArrayList(shape_wire.Entry) = .empty;

        std.debug.assert(name.len > 0);

        try shape_parts.table_of(Shape, self.arena_allocator, value, &table);

        return .{
            .name = @intCast(@intFromPtr(name.ptr)),
            .name_len = @intCast(name.len),
            .root = @intCast(@intFromPtr(value)),
            .asked = @intCast(@intFromPtr(described.ptr)),
            .asked_len = described.len,
            .table = @intCast(@intFromPtr(table.items.ptr)),
            .table_len = @intCast(table.items.len),
        };
    }

    /// What the administrator granted for a request: whether the key is on, and its flags.
    pub fn grant(self: *const SandboxApi, comptime key: []const u8) permission_define.Grant {
        std.debug.assert(self.name.len > 0);

        comptime std.debug.assert(permission.find(key) != null);

        var granted = permission_define.grant_from_bits(publr_granted(key.ptr, key.len) & 0x1f);

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
    /// Text in the call's language, from the host's catalogues as a compiled-in plugin's
    /// `ctx.t` reads them; the source text where no language pack has it.
    pub fn t(self: *const SandboxApi, comptime text: []const u8, values: anytype) []const u8 {
        comptime std.debug.assert(text.len > 0);

        const said = translated(self.arena_allocator, text, "", null) orelse text;

        return filled_in(self.arena_allocator, said, values) catch said;
    }

    pub fn tn(
        self: *const SandboxApi,
        comptime one: []const u8,
        comptime many: []const u8,
        count: u64,
        values: anytype,
    ) []const u8 {
        comptime std.debug.assert(one.len > 0 and many.len > 0);

        const source = if (count == 1) one else many;
        const said = translated(self.arena_allocator, one, many, count) orelse source;

        return filled_in(self.arena_allocator, said, values) catch said;
    }

    /// Words marked where they were written (`publr.t`, `ctx.t`) and kept as written: a
    /// label another plugin registered or stored (a line's work, `To send`), in the
    /// caller's language when shown. The text itself where no language pack has it.
    pub fn translate(self: *const SandboxApi, text: []const u8) []const u8 {
        std.debug.assert(self.name.len > 0);

        if (text.len == 0) {
            return text;
        }

        return translated(self.arena_allocator, text, "", null) orelse text;
    }

    /// The language the call speaks (`pl`, `en`): what `t` answers in.
    pub fn language(self: *const SandboxApi) []const u8 {
        std.debug.assert(self.name.len > 0);
        std.debug.assert(self.now_at_ms >= 0);

        return self.language_code;
    }

    /// `ctx.locale(person)`: the call's language until installed plugins' catalogues reach
    /// the host per person.
    pub fn locale_code(self: *const SandboxApi, person: []const u8) []const u8 {
        std.debug.assert(self.name.len > 0);
        std.debug.assert(self.now_at_ms >= 0);
        _ = person;

        return self.language_code;
    }

    /// `t` and `tn` for `ctx.locale(…)`: in the call's language, as `locale_code` says.
    pub fn said_in(
        self: *const SandboxApi,
        code: []const u8,
        comptime text: []const u8,
        comptime plural: []const u8,
        count: ?u64,
        values: anytype,
    ) []const u8 {
        std.debug.assert(self.name.len > 0);
        _ = code;

        if (comptime plural.len == 0) {
            return self.t(text, values);
        }

        return self.tn(text, plural, count orelse 0, values);
    }

    /// Memory of its own for one step of an operation. From here until `end`, everything the
    /// call allocates and reads (`ctx.arena()`, records, answers) is in the scope's memory, and
    /// `end` gives all of it back: an operation then takes the memory of its largest step, never
    /// the sum of its steps. Nothing made inside may be used after `end`; a number or an enum
    /// is carried out by value, anything else is copied into memory taken before the scope.
    ///
    ///     var step = ctx.scope();
    ///     defer step.end();
    ///
    /// `leave` goes back to the operation's memory while what the scope holds stays readable
    /// until `end`: for something read once and used across later steps.
    pub fn scope(self: *SandboxApi) Scope {
        const outer = self.arena_allocator;

        std.debug.assert(self.name.len > 0);

        const held = outer.create(guest_memory.Arena) catch {
            // No room even for that: the step works in the operation's memory.
            return .{
                .api = self,
                .outer = outer,
                .memory = null,
                .walks_mark = walks_guest.depth(),
            };
        };

        held.* = guest_memory.arena();
        self.arena_allocator = held.allocator();

        return .{
            .api = self,
            .outer = outer,
            .memory = held,
            .walks_mark = walks_guest.depth(),
        };
    }

    pub const Scope = struct {
        api: *SandboxApi,
        outer: std.mem.Allocator,
        memory: ?*guest_memory.Arena,
        inside: bool = true,
        /// Walks open when the scope began: those opened inside it go with it.
        walks_mark: u32,

        /// Back to the memory the call had before the scope; what the scope holds stays.
        pub fn leave(self: *Scope) void {
            if (!self.inside or self.memory == null) {
                return;
            }

            walks_guest.leave_above(self.api, self.walks_mark);

            // Scopes nest: one opened inside this one has ended.
            std.debug.assert(self.api.arena_allocator.ptr == @as(*anyopaque, self.memory.?));

            self.inside = false;
            self.api.arena_allocator = self.outer;
        }

        /// `text` copied into the memory the call had before the scope: what a step carries out
        /// when it is more than a number.
        pub fn keep(self: *Scope, text: []const u8) error{OutOfMemory}![]const u8 {
            return self.outer.dupe(u8, text);
        }

        /// Everything the scope holds is given back.
        pub fn end(self: *Scope) void {
            self.leave();
            walks_guest.end_above(self.api, self.walks_mark);
            // Ended once: walks opened after this never go with it.
            self.walks_mark = std.math.maxInt(u32);

            const held = self.memory orelse return;
            const api = self.api;

            std.debug.assert(!self.inside);

            // The reads remembered inside are forgotten: their answers go with the memory.
            if (api.memo) |memo| {
                memo.drop(held);
            }

            // A refusal's name outlives the step that met it.
            if (api.last_failure.len > 0) {
                api.last_failure = self.outer.dupe(u8, api.last_failure) catch "";
            }

            if (api.last_message.len > 0) {
                api.last_message = self.outer.dupe(u8, api.last_message) catch "";
            }

            held.deinit();
            self.memory = null;
        }
    };

    pub fn arena(self: *const SandboxApi) std.mem.Allocator {
        std.debug.assert(self.now_at_ms >= 0);
        std.debug.assert(self.name.len > 0);

        return self.arena_allocator;
    }

    /// `mod` for many values at once: a cart's lines, an order's charges. Each modifier
    /// hears them in batches with its reads made together for all, so the cost is one call
    /// per batch, never one per value. Answers them in the same order.
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

        runtime.uses("mod", name);

        const memory = self.arena();
        const changed = memory.alloc(Value, values.len) catch return error.OutOfMemory;
        var start: usize = 0;

        while (start < values.len) {
            const end = @min(values.len, start + mods.items_max);
            const batch = values[start..end];
            // The values go as they lie and come back as they lie: no text written or read here.
            const Sent = struct {
                name: []const u8,
                values: []const Value,
            };
            const Got = struct {
                values: []const Value,
            };
            const answered = try self.call_shaped(Sent, Got, mods.Apply.name, &.{
                .name = name,
                .values = batch,
            });
            const made = answered.values;

            @memcpy(changed[start..end], if (made.len == batch.len) made else batch);
            start = end;
        }

        std.debug.assert(changed.len == values.len);

        return changed;
    }

    /// Runs `Operation` in the host as this plugin, with its grants: `error.Denied` when an
    /// administrator has not granted (or has revoked) what it needs.
    pub fn call(self: *SandboxApi, comptime Operation: type, in: Operation.In) Error!Operation.Out {
        const own = comptime @hasDecl(Operation, "publr_operation_definition");

        if (comptime !own) {
            comptime runtime.check_call(Operation.name);
            runtime.uses("call", Operation.name);
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

        const read = comptime @hasDecl(Operation, "kind") and Operation.kind == .read;

        if (comptime !read) {
            // What it writes may change what was read: the call's reads are asked again.
            if (self.memo) |memo| {
                memo.forget();
            }

            return self.call_shaped(Operation.In, Operation.Out, operation_name, &in);
        }

        return self.read_shaped(Operation.In, Operation.Out, operation_name, &in);
    }

    /// A read, answered from what this call read already when nothing was written since:
    /// inside one call no one else writes.
    pub fn read_shaped(
        self: *SandboxApi,
        comptime In: type,
        comptime Out: type,
        name: []const u8,
        in: *const In,
    ) Error!Out {
        std.debug.assert(name.len > 0);

        const memo = self.memo orelse return self.call_shaped(In, Out, name, in);
        // What was asked, as bytes that are the same for the same value: read where it
        // lies, nothing built.
        const input = laid_key.of(self.arena_allocator, in.*) catch return error.OutOfMemory;

        if (memo.find(Out, name, input)) |answered| {
            self.last_failure = "";
            self.last_message = "";
            return answered;
        }

        const out = try self.call_shaped(In, Out, name, in);

        try memo.keep(self.arena_allocator, Out, name, input, out);

        return out;
    }

    /// Calls `name` with `in` in this module's own layout, the answer laid out by the host as
    /// an `Out`: no text written or read here.
    pub fn call_shaped(
        self: *SandboxApi,
        comptime In: type,
        comptime Out: type,
        name: []const u8,
        in: *const In,
    ) Error!Out {
        std.debug.assert(name.len > 0);

        comptime {
            if (@typeInfo(Out) != .@"struct") {
                @compileError("an operation answers a struct, not " ++ @typeName(Out));
            }
        }

        const memory = self.arena_allocator;
        const asked = comptime shape_wire.describe(In);
        const answer = comptime shape_wire.describe(Out);
        var table: std.ArrayList(shape_wire.Entry) = .empty;

        try shape_parts.table_of(In, memory, in, &table);

        var sizes: [2]u32 = .{ 0, 0 };
        const call_parts: shape_wire.Call = .{
            .name = @intCast(@intFromPtr(name.ptr)),
            .name_len = @intCast(name.len),
            .root = @intCast(@intFromPtr(in)),
            .asked = @intCast(@intFromPtr(asked.ptr)),
            .asked_len = asked.len,
            .table = @intCast(@intFromPtr(table.items.ptr)),
            .table_len = @intCast(table.items.len),
            .answer = @intCast(@intFromPtr(answer.ptr)),
            .answer_len = answer.len,
        };
        const status = if (self.alone)
            publr_call_alone(&call_parts, &sizes)
        else
            publr_call_shaped(&call_parts, &sizes);

        self.last_failure = "";
        self.last_message = "";

        if (status != wire.ok) {
            return self.refused(status, sizes[0]);
        }

        return self.taken(Out, sizes);
    }

    /// A refusal, its name kept for `failure()` when the host sent one.
    fn refused(self: *SandboxApi, status: u32, len: u32) Error {
        std.debug.assert(status != wire.ok);

        if (status == wire.code_of(error.Failed) and len > 0) {
            const named = self.arena_allocator.alloc(u8, len) catch return error.OutOfMemory;

            if (publr_shaped_take(@intCast(@intFromPtr(named.ptr)), 0) == wire.ok) {
                self.last_failure = named;
                self.last_message = asks.message_of_refusal(self);
            }
        }

        return wire.error_of(status);
    }

    /// The answer waiting in the host, written into room made in the call's arena.
    fn taken(self: *SandboxApi, comptime Out: type, sizes: [2]u32) Error!Out {
        std.debug.assert(self.name.len > 0);

        return taken_as(Out, self.arena_allocator, sizes);
    }

    /// Calls an operation by a name known only when it runs (a contract's provider), `in`
    /// as it lies, the answer laid out as an `Out`.
    pub fn call_named(
        self: *SandboxApi,
        comptime Out: type,
        name: []const u8,
        in: anytype,
    ) Error!Out {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.reads == null);

        return self.call_shaped(@TypeOf(in), Out, name, &in);
    }

    /// Calls an operation by name with a value whose shape comes with the data, and answers
    /// one: for a caller that learns what to send only when it runs.
    pub fn call_value(
        self: *SandboxApi,
        name: []const u8,
        input: free_value.Value,
    ) Error!free_value.Value {
        const Json = operation_contract.Json;
        const Free = struct {
            value: Json,

            pub const publr_form = .inner;
        };

        std.debug.assert(name.len > 0);

        const answered = try self.call_shaped(Free, Free, name, &.{
            .value = .{
                .bytes = input.bytes,
            },
        });

        return .{
            .bytes = answered.value.bytes,
        };
    }

    /// Which refusal the last `call` came back with as `error.Failed`, or the plugin's own
    /// `fail` named, by its `Fails:` name (`NotEnoughStock`); empty when there was none.
    pub fn failure(self: *const SandboxApi) []const u8 {
        std.debug.assert(self.name.len > 0);

        return self.last_failure;
    }

    /// Emits an event made with `publr.event.define`, its payload as it lies: the host runs
    /// its `after` hooks inside the write and queues it for the `on` hooks.
    pub fn emit(self: *SandboxApi, comptime Event: type, payload: Event.Payload) void {
        std.debug.assert(self.name.len > 0);
        comptime std.debug.assert(@hasDecl(Event, "publr_event_definition"));

        if (comptime Event.full_name.len > 0) {
            runtime.uses("emit", Event.full_name);
        }

        const name = if (comptime Event.full_name.len > 0)
            Event.full_name
        else
            std.fmt.allocPrint(self.arena_allocator, "{s}.{s}", .{ self.name, Event.verb }) catch
                return;
        const parts = self.sent(Event.Payload, name, &payload) catch return;

        publr_emit(&parts);
    }

    /// Refuses the call in the plugin's own words: `return ctx.fail(.NotEnoughStock, "Only
    /// {left} left", .{ .left = 2 })`. The name is what a form's redirect carries
    /// (`?error=NotEnoughStock`), the message what a person reads. The write rolls back like
    /// any other error's.
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
        self.last_failure = tag;
        self.last_message = message;

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

    /// A line in the host's log, attributed to the plugin.
    pub fn log(
        self: *SandboxApi,
        comptime level: words.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        std.debug.assert(self.name.len > 0);
        comptime std.debug.assert(format.len > 0);

        const line = std.fmt.allocPrint(self.arena_allocator, format, args) catch format;

        publr_log_at(@backingInt(level), line.ptr, @intCast(line.len));
    }
};

extern "env" fn publr_translate(asked: *const wire.Message, result: *wire.Result) u32;

/// One message in the call's language, as the host's catalogues have it; null for English
/// or a message no language pack has.
fn translated(
    arena: std.mem.Allocator,
    id: []const u8,
    plural: []const u8,
    count: ?u64,
) ?[]const u8 {
    std.debug.assert(id.len > 0);

    const asked = wire.Message.of("", id, plural, if (count) |number|
        @as(?f64, @floatFromInt(number))
    else
        null);
    var result: wire.Result = .{
        .ptr = 0,
        .len = 0,
    };

    if (publr_translate(&asked, &result) != wire.ok) {
        return null;
    }

    const told = take(result);
    defer allocator.free(told);

    if (told.len == 0) {
        return null;
    }

    return arena.dupe(u8, told) catch null;
}

/// `text` with each `{name}` of `values` filled, as `words.filled` does for a text known at
/// build time.
fn filled_in(
    arena: std.mem.Allocator,
    text: []const u8,
    values: anytype,
) error{OutOfMemory}![]const u8 {
    std.debug.assert(text.len < 1 << 24);

    var out: []const u8 = text;

    inline for (comptime std.meta.fieldNames(@TypeOf(values))) |field_name| {
        const hole = "{" ++ field_name ++ "}";
        const value = try words.shown(arena, @field(values, field_name));

        out = try std.mem.replaceOwned(u8, arena, out, hole, value);
    }

    return out;
}

/// The value waiting in the host, written into room made in `memory`: `sizes` is what the
/// host said it takes.
pub fn taken_as(comptime Out: type, memory: std.mem.Allocator, sizes: [2]u32) Error!Out {
    std.debug.assert(sizes[0] >= @sizeOf(Out));

    const block = memory.alignedAlloc(u8, .@"16", sizes[0]) catch return error.OutOfMemory;
    const table = memory.alloc(shape_wire.Entry, sizes[1]) catch return error.OutOfMemory;
    const block_at: u32 = @intCast(@intFromPtr(block.ptr));

    if (publr_shaped_take(block_at, @intCast(@intFromPtr(table.ptr))) != wire.ok) {
        return error.Invalid;
    }

    const out: *Out = @ptrCast(@alignCast(block.ptr));
    var next: u32 = 0;

    try shape_parts.fill(Out, out, table, &next);

    return out.*;
}

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
        @export(&Generated.shape, .{
            .name = "publr_shape",
        });
        @export(&Generated.invoke_shaped, .{
            .name = "publr_invoke_shaped",
        });
        @export(&Generated.invoke_batch, .{
            .name = "publr_invoke_batch",
        });
        @export(&Generated.manifest, .{
            .name = "publr_manifest",
        });

        if (@hasField(@TypeOf(Plugin.options), "translations")) {
            @export(&Generated.translations, .{
                .name = "publr_translations",
            });
        }
    }
}

/// The exports a plugin's module gives the host: memory for the host to write into, and one
/// entry point for every operation and hook, numbered in manifest order.
pub fn Exports(comptime Plugin: type) type {
    comptime @import("sandboxed.zig").every_hook_has_words(Plugin);

    const entries = contract.runtime_entries(Plugin);

    return struct {
        /// Whose fields an `after` hook adds to a list read's rows.
        const plugin_name: []const u8 = Plugin.manifest.name;

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

            var arena_state = guest_memory.arena();
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

        /// The plugin's translations as JSON, PO text included, for building into the
        /// module's `publr.translations` section. Exported only by a plugin that brings some.
        pub fn translations(result_ptr: u32) callconv(.c) u32 {
            std.debug.assert(result_ptr != 0);

            const result: *wire.Result = @ptrFromInt(result_ptr);
            var output: std.Io.Writer.Allocating = .init(allocator);
            const brought: []const contract.Translation = comptime plugin_define.get(
                Plugin,
                "translations",
            );

            std.json.Stringify.value(brought, .{}, &output.writer) catch {
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

        /// `publr_shape(entry, which, result)`: how entry `entry`'s envelope (`which` 0) is
        /// laid out in this build, for the host to write its input in.
        pub fn shape(entry: u32, which: u32, result_ptr: u32) callconv(.c) u32 {
            std.debug.assert(result_ptr != 0);
            std.debug.assert(which == 0);

            const result: *wire.Result = @ptrFromInt(result_ptr);

            inline for (entries, 0..) |item, index| {
                if (entry == index) {
                    const text = comptime shape_wire.describe(EnvelopeOf(item));

                    result.* = .{
                        .ptr = @intCast(@intFromPtr(text.ptr)),
                        .len = text.len,
                    };

                    return wire.ok;
                }
            }

            return wire.code_of(error.NotFound);
        }

        /// What entry `item` takes, laid out: its own input inside what every entry reads
        /// around it (`wire.Envelope`).
        fn EnvelopeOf(comptime item: contract.Entry) type {
            const field_kind = @import("../../publr/plugin/field_kind_define.zig");
            const declared = item.declaration;

            return switch (item.stage) {
                .operation => wire.Envelope(declared.In, wire.None),
                .before => wire.Envelope(contract.HookIn(declared), wire.None),
                .after => wire.Envelope(contract.HookIn(declared), contract.HookOut(declared)),
                .event => wire.Envelope(declared.Payload, wire.None),
                // A modifier takes its values as its own type: only the fields it declares.
                .modify => wire.Envelope(modify_define.Items(declared.Value), wire.None),
                .job => JobEnvelope(declared),
                .rule_values => wire.Envelope(wire.None, wire.None),
                .rule_matches => wire.Envelope(
                    @import("location_rules.zig").Asked,
                    wire.None,
                ),
                .kind_validate, .kind_text => wire.Envelope(field_kind.Stored, wire.None),
                .kind_editor, .dimension_options => wire.Envelope(field_kind.Drawn, wire.None),
            };
        }

        /// A job's envelope: one type however often it is named.
        fn JobEnvelope(comptime Job: type) type {
            comptime std.debug.assert(job_define.is_job(Job));

            return wire.Envelope(JobIn(Job), wire.None);
        }

        /// What a job's envelope carries as its input: nothing, the record a `.due` job is
        /// about, or the job's own input.
        fn JobIn(comptime Job: type) type {
            comptime std.debug.assert(job_define.is_job(Job));

            if (Job.Input == void) {
                return wire.None;
            }

            return if (Job.due_on != null) job_define.DueInput else Job.Input;
        }

        /// `publr_invoke_batch(entry, items, count)`: entry `entry` run once for each of the
        /// envelopes the host laid out, in order, in one call: a hook core fires for many
        /// items at once. Each run has memory of its own, given back before the next, and
        /// tells the host how it ended (`publr_item`) before the next begins.
        pub fn invoke_batch(entry: u32, items: u32, count: u32) callconv(.c) u32 {
            std.debug.assert(items != 0);
            std.debug.assert(count > 0);

            const start: [*]const shape_wire.Item = @ptrFromInt(items);

            for (start[0..count], 0..) |item, index| {
                const status = invoke_shaped(entry, item.block, item.table, item.count);

                publr_item(@intCast(index), status);
            }

            return wire.ok;
        }

        /// `publr_invoke_shaped(entry, block, table, count)`: entry `entry` run with its
        /// envelope laid out at `block` by the host; its answer handed back by `publr_answer`.
        pub fn invoke_shaped(entry: u32, block: u32, table: u32, count: u32) callconv(.c) u32 {
            std.debug.assert(block != 0);
            std.debug.assert(table != 0 or count == 0);

            var arena_state = guest_memory.arena();
            defer arena_state.deinit();

            // Walks the entry left open go with it, before its memory.
            const walks_mark = walks_guest.depth();
            defer walks_guest.end_above(null, walks_mark);

            const start: [*]const shape_wire.Entry = @ptrFromInt(@max(table, 8));
            const laid = if (count == 0) &[_]shape_wire.Entry{} else start[0..count];

            inline for (entries, 0..) |item, index| {
                if (entry == index) {
                    const Shape = EnvelopeOf(item);
                    const envelope: *Shape = @ptrFromInt(block);
                    var next: u32 = 0;

                    shape_parts.fill(Shape, envelope, laid, &next) catch |err| {
                        return wire.code_of(err);
                    };

                    run(item, envelope, arena_state.allocator()) catch |err| {
                        return wire.code_of(err);
                    };

                    return wire.ok;
                }
            }

            return wire.code_of(error.NotFound);
        }

        fn run(
            comptime item: contract.Entry,
            envelope: *EnvelopeOf(item),
            arena: std.mem.Allocator,
        ) Error!void {
            const declared = item.declaration;

            return switch (item.stage) {
                .operation => run_operation(declared, envelope, arena),
                .before, .after, .event => run_hook(item, envelope, arena),
                .modify => run_modify(declared, envelope, arena),
                .job => run_job(declared, envelope.*, arena),
                .rule_values, .rule_matches => run_rule(item, envelope, arena),
                .kind_validate, .kind_text => run_kind(item, envelope, arena),
                .kind_editor, .dimension_options => run_drawn(item, envelope, arena),
            };
        }

        /// A hook run on an envelope the host laid out; a `before` answers its input as it
        /// left it, an `after` on a list read the fields it added to the rows.
        fn run_hook(
            comptime item: contract.Entry,
            envelope: *EnvelopeOf(item),
            arena: std.mem.Allocator,
        ) Error!void {
            var ctx = context(arena, envelope.*);

            switch (comptime item.stage) {
                .before => {
                    try item.declaration.run(ctx.ctx(), &envelope.in);
                    try hand_back(@TypeOf(envelope.in), arena, &envelope.in);
                },
                .after => {
                    var out = envelope.out orelse return error.Invalid;

                    if (comptime !@hasField(@TypeOf(out), "extended")) {
                        return item.declaration.run(ctx.ctx(), &envelope.in, &out);
                    }

                    const Extended = @import("../extended.zig").Extended;

                    out.extended = try Extended.start(arena, &plugin_name);
                    try item.declaration.run(ctx.ctx(), &envelope.in, &out);
                    try out.extended.seal();
                    try hand_back(Extended, arena, &out.extended);
                },
                .event => try item.declaration.run(ctx.ctx(), envelope.in),
                else => unreachable,
            }
        }

        /// A modifier run over values the host laid out as its own type; it answers them as
        /// it left them, for the host to lay over the owner's.
        fn run_modify(
            comptime Modifier: type,
            envelope: *wire.Envelope(modify_define.Items(Modifier.Value), wire.None),
            arena: std.mem.Allocator,
        ) Error!void {
            var ctx = context(arena, envelope.*);

            std.debug.assert(envelope.in.items.len <= mods.items_max);

            const items = envelope.in.items;

            if (comptime Modifier.whole) {
                try modify_define.run_all(Modifier.Value, Modifier.run_one, ctx.ctx(), items);
            } else {
                try modify_define.run_values(Modifier.Value, Modifier.run_one, ctx.ctx(), items);
            }

            try hand_back(@TypeOf(envelope.in), arena, &envelope.in);
        }

        fn run_operation(
            comptime Operation: type,
            envelope: *wire.Envelope(Operation.In, wire.None),
            arena: std.mem.Allocator,
        ) Error!void {
            var ctx = context(arena, envelope.*);
            var memo: read_memo.Memo = .{
                .home = arena,
            };

            ctx.failures = comptime words.failures_of(Operation);
            ctx.memo = &memo;

            try lists_fit(&ctx, Operation.In, &envelope.in, .input);

            const out = try Operation.run(ctx.ctx(), envelope.in, &Grant.allow_all);

            try lists_fit(&ctx, Operation.Out, &out, .output);
            try hand_back(Operation.Out, arena, &out);
        }

        /// Every list of an input or an answer within its limit, as core holds a compiled-in
        /// operation's (`operation/lists.zig`): an input past it is refused, named at the
        /// list; an answer past it fails the call, the operation's own fault.
        fn lists_fit(
            ctx: *SandboxApi,
            comptime Value: type,
            value: *const Value,
            comptime side: enum { input, output },
        ) Error!void {
            const over = operation_contract.lists.over_limit(Value, value) orelse return;
            const message = std.fmt.allocPrint(ctx.arena(), switch (side) {
                .input => "At most {d}",
                .output => "The answer holds more than {d} here: answer it a page at a time",
            }, .{over.limit}) catch return error.OutOfMemory;

            std.debug.assert(over.path.len > 0);

            return ctx.refuse(&.{.{
                .field = over.path,
                .message = message,
            }});
        }

        /// A location rule's dropdown values, or whether it matches the account or file
        /// being edited.
        fn run_rule(
            comptime item: contract.Entry,
            envelope: *EnvelopeOf(item),
            arena: std.mem.Allocator,
        ) Error!void {
            const rule = item.declaration.rule;
            var ctx = context(arena, envelope.*);

            if (comptime item.stage == .rule_values) {
                const values = try rule.values(ctx.ctx());

                return hand_back(@TypeOf(values), arena, &values);
            }

            const matches: bool = try rule.matches(ctx.ctx(), envelope.in.target, envelope.in.rule);

            return hand_back(bool, arena, &matches);
        }

        /// A field kind's `.validate` over one stored value (the problems it finds), or how
        /// the value reads, by its `.text`.
        fn run_kind(
            comptime item: contract.Entry,
            envelope: *EnvelopeOf(item),
            arena: std.mem.Allocator,
        ) Error!void {
            const field_kind = @import("../../publr/plugin/field_kind_define.zig");
            const Definition = item.declaration;
            var ctx = context(arena, envelope.*);

            if (comptime item.stage == .kind_validate) {
                const problems = field_kind.problems_stored(Definition, arena, envelope.in);

                return hand_back([]const []const u8, arena, &problems);
            }

            if (comptime !@hasField(@TypeOf(Definition.given), "text")) {
                return error.NotFound;
            }

            const parsed = field_kind.stored_as(Definition.Shape, arena, envelope.in) catch {
                return error.Invalid;
            };
            const text: []const u8 = try Definition.given.text(ctx.ctx(), parsed);

            return hand_back([]const u8, arena, &text);
        }

        /// A field kind's `.editor` view, or a dimension's `.options` view, drawn whole for
        /// its frame under the `base` asked; what the view shows comes with the caller's view.
        fn run_drawn(
            comptime item: contract.Entry,
            envelope: *EnvelopeOf(item),
            arena: std.mem.Allocator,
        ) Error!void {
            const views = @import("../../publr/plugin/views.zig");
            const declared = item.declaration;
            var ctx = context(arena, envelope.*);

            if (comptime item.stage == .dimension_options) {
                const field = declared.dimension.api.field;

                if (comptime !field.drawn) {
                    return error.NotFound;
                }

                const html: []const u8 = try views.render(
                    ctx.ctx(),
                    envelope.in.base,
                    field.view,
                    .{},
                );

                return hand_back([]const u8, arena, &html);
            }

            if (comptime !@hasField(@TypeOf(declared.given), "editor")) {
                return error.NotFound;
            }

            const html: []const u8 = try views.render(
                ctx.ctx(),
                envelope.in.base,
                declared.given.editor,
                .{},
            );

            return hand_back([]const u8, arena, &html);
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
                .language_code = envelope.language,
                .facts = envelope.caller,
            };
        }

        /// A queued job: its input, and whether this is its last attempt, when `.on_failure`
        /// hears why it failed.
        fn run_job(
            comptime Job: type,
            envelope: JobEnvelope(Job),
            arena: std.mem.Allocator,
        ) Error!void {
            const due = comptime Job.due_on != null;
            var base = context(arena, envelope);
            var ctx: queue.QueueCtx = .{
                .base = base.ctx(),
            };
            // A `.due` job gets its record as it is now; one gone or in the trash runs nothing.
            const in: Job.Input = if (comptime Job.Input == void) {} else if (due)
                Job.Record.get(&ctx, envelope.in.record, .{}) catch |err| {
                    return if (err == error.NotFound) {} else err;
                }
            else
                envelope.in;
            const ran = if (comptime Job.Input == void)
                Job.run(&ctx)
            else
                Job.run(&ctx, in);

            ran catch |err| {
                // A conflict ends the job: `.on_conflict` hears it now, the host keeps it.
                if (err == error.Conflict and comptime @TypeOf(Job.on_conflict) != @TypeOf(null)) {
                    // What the run wrote is undone; what `.on_conflict` writes is kept.
                    publr_undo();

                    if (comptime Job.Input == void) {
                        Job.on_conflict(&ctx);
                    } else {
                        Job.on_conflict(&ctx, in);
                    }

                    return err;
                }

                if (envelope.last and comptime @TypeOf(Job.on_failure) != @TypeOf(null)) {
                    publr_undo();

                    if (comptime Job.Input == void) {
                        Job.on_failure(&ctx, err);
                    } else {
                        Job.on_failure(&ctx, in, err);
                    }
                }

                return err;
            };
        }
    };
}

/// An entry's answer handed to the host in this module's own layout, while it is still here.
fn hand_back(comptime Out: type, arena: std.mem.Allocator, out: *const Out) Error!void {
    const text = comptime shape_wire.describe(Out);
    var table: std.ArrayList(shape_wire.Entry) = .empty;

    std.debug.assert(text.len > 0);

    try shape_parts.table_of(Out, arena, out, &table);

    const status = publr_answer(
        text.ptr,
        text.len,
        @intCast(@intFromPtr(out)),
        @intCast(@intFromPtr(table.items.ptr)),
        @intCast(table.items.len),
    );

    if (status != wire.ok) {
        return wire.error_of(status);
    }
}

extern "env" fn publr_answer(
    description_ptr: [*]const u8,
    description_len: u32,
    root: u32,
    table_ptr: u32,
    table_len: u32,
) u32;
