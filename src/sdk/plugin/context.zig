const std = @import("std");
const held_of = @import("../../model/sandboxed_plugin.zig").held_of;
const mods = @import("../mods.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const words = @import("../../publr/plugin/words.zig");
const permission_define = @import("permission_define.zig");
const Ask = @import("../../model/sandboxed_plugin.zig").Ask;
const caller_view = @import("caller_view.zig");
const role = @import("../../model/role.zig");
const job_define = @import("../../publr/plugin/job_define.zig");
const job_queue = @import("../../store/job_queue.zig");
const permission_model = @import("../../model/permission.zig");
const user_language = @import("../../operations/user/language.zig");
const plugin_memory = @import("../plugin_memory.zig");
const free_value = @import("../../publr/free_value.zig");

pub const Caller = sdk.Caller;
pub const Error = sdk.Error;

/// What a plugin's operations and hooks take, declared in `publr/ctx.zig`: behind it the
/// call's `HostApi` when the plugin is built in, its `SandboxApi` when installed.
pub const PluginCtx = @import("../../publr/ctx.zig").Ctx;

/// The compiled-in call behind a plugin's `ctx`: core's own way in, never the plugin's.
pub fn host_of(ctx: anytype) HostOf(@TypeOf(ctx)) {
    comptime std.debug.assert(guest.mode == .native);

    if (comptime std.meta.Child(@TypeOf(ctx)) == HostApi) {
        return ctx;
    }

    return @ptrCast(@alignCast(ctx));
}

/// The call behind a plugin's `ctx` in this build, compiled in or installed: the SDK's own
/// way to what the plugin does not see (a modifier's batched reads, a read's memo).
pub fn behind_of(ctx: anytype) BehindOf(@TypeOf(ctx)) {
    if (comptime std.meta.Child(@TypeOf(ctx)) != PluginCtx) {
        return ctx;
    }

    return @ptrCast(@alignCast(ctx));
}

fn BehindOf(comptime Pointer: type) type {
    const Behind = switch (guest.mode) {
        .sandboxed => guest.SandboxApi,
        .native => HostApi,
    };

    if (std.meta.Child(Pointer) != PluginCtx) {
        return Pointer;
    }

    return if (@typeInfo(Pointer).pointer.attrs.@"const") *const Behind else *Behind;
}

fn HostOf(comptime Pointer: type) type {
    if (std.meta.Child(Pointer) == HostApi) {
        return Pointer;
    }

    return if (@typeInfo(Pointer).pointer.attrs.@"const") *const HostApi else *HostApi;
}

pub const Mode = guest.Mode;

const guest = @import("guest.zig");
const mod_reads = @import("mod_reads.zig");

/// A native plugin's way into Publr: direct calls through the SDK, full access.
pub const HostApi = struct {
    inner: *sdk.Ctx,
    /// Set while a modifier runs: its reads are noted and answered for the whole batch.
    reads: ?*mod_reads.Reads = null,

    /// The plugin's `ctx` this call stands behind.
    pub fn ctx(self: *HostApi) *PluginCtx {
        return @ptrCast(self);
    }

    /// Who is calling: where from, whether signed in, their roles, whether an
    /// administrator granted them this operation, the visitor's stable id.
    pub fn caller(self: *const HostApi) caller_view.View {
        std.debug.assert(self.inner.now_ms >= 0);
        std.debug.assert(self.inner.next_operation_id > 0);

        const through_app = self.inner.app_plugins != null;
        const raw = self.inner.caller;
        const granted_here = !through_app and self.inner.within.len > 0 and
            granted_by_role(self.inner, self.inner.within);

        const by_plugin = self.inner.plugin_called and self.inner.called_by.len > 0;
        const from: caller_view.From = if (by_plugin) .{
            .plugin = self.inner.called_by,
        } else caller_view.from_of(raw, through_app, self.inner.over_api, self.inner.job);

        return caller_view.view_of(raw, .{
            .from = from,
            .visitor = self.inner.visitor,
            .referer = self.inner.referer,
            .granted_here = granted_here,
        });
    }

    fn granted_by_role(inner: *const sdk.Ctx, operation_name: []const u8) bool {
        std.debug.assert(operation_name.len > 0);

        const raw = inner.caller;

        if (raw == .system) {
            return true;
        }

        const held = raw.roles() orelse return false;

        return sdk.stored_roles.allows(inner, held, operation_name);
    }

    /// What the plugin was given for a request: compiled in, exactly what its `.permissions`
    /// asked for, since whoever built the binary chose its plugins.
    pub fn grant(self: *const HostApi, comptime key: []const u8) permission_define.Grant {
        std.debug.assert(self.inner.now_ms >= 0);

        return permission_define.Grant.of(key, held_of_running(self.inner.plugin, key));
    }

    pub fn now(self: *const HostApi) words.Time {
        std.debug.assert(self.inner.now_ms >= 0);

        return .{
            .ms = self.inner.now_ms,
        };
    }

    /// `ctx.enqueue_at`: in the queue's table, inside the call's transaction.
    pub fn enqueue_at(
        self: *HostApi,
        comptime Job: type,
        in: Job.Input,
        at: words.Time,
    ) Error!void {
        comptime std.debug.assert(job_define.is_job(Job));
        std.debug.assert(self.inner.plugin.len > 0);

        if (comptime Job.due_on != null) {
            @compileError("job " ++ Job.verb ++ " runs when its record's field says: " ++
                "`.due` jobs are not queued by code");
        }

        const memory = self.inner.arena;
        const input = std.json.Stringify.valueAlloc(memory, in, .{}) catch return error.OutOfMemory;

        if (input.len > job_queue.input_bytes_max) {
            return error.Invalid;
        }

        try job_queue.push(self.inner.db, .{
            .plugin = self.inner.plugin,
            .name = Job.verb,
            .input = input,
            .due_at_ms = @max(at.ms, self.inner.now_ms),
            .now_ms = self.inner.now_ms,
            .language = self.inner.language_queued(),
        });
    }

    /// SQL on the plugin's own tables (`host.table`), inside the call's transaction. Only a
    /// plugin with `.extend` has tables; an installed plugin's ctx has no `database`.
    pub fn database(self: *const HostApi) @import("host.zig").Database {
        std.debug.assert(self.inner.now_ms >= 0);

        return .{
            .connection = self.inner.db,
        };
    }

    /// Memory freed when the call ends.
    pub fn alloc(
        self: *const HostApi,
        comptime Item: type,
        count: u32,
    ) error{OutOfMemory}![]Item {
        std.debug.assert(count <= 1 << 24);

        return self.inner.arena.alloc(Item, count);
    }

    /// Formatted text in memory freed when the call ends.
    pub fn print(
        self: *const HostApi,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        comptime std.debug.assert(format.len > 0);

        return std.fmt.allocPrint(self.inner.arena, format, args);
    }

    /// Text for people, in the caller's language, each `{name}` filled from `values`.
    pub fn t(self: *const HostApi, comptime text: []const u8, values: anytype) []const u8 {
        comptime std.debug.assert(text.len > 0);

        return self.said(text, "", null, values);
    }

    /// The same for a count: `ctx.tn("{count} item", "{count} items", count, .{ .count = count })`.
    pub fn tn(
        self: *const HostApi,
        comptime one: []const u8,
        comptime many: []const u8,
        count: u64,
        values: anytype,
    ) []const u8 {
        comptime std.debug.assert(one.len > 0 and many.len > 0);

        return self.said(one, many, count, values);
    }

    /// Words marked where they were written (`publr.t`, `ctx.t`) and kept as written: a
    /// label another plugin registered or stored (a line's work, `To send`), in the
    /// caller's language when shown. The text itself where no language pack has it.
    pub fn translate(self: *const HostApi, text: []const u8) []const u8 {
        std.debug.assert(self.inner.now_ms >= 0);

        if (text.len == 0) {
            return text;
        }

        return self.inner.say(self.speaks(), .{
            .id = text,
            .plural = "",
            .count = null,
            .values = &.{},
        }) catch text;
    }

    /// The language the call speaks (`pl`, `en`): what `t` answers in.
    pub fn language(self: *const HostApi) []const u8 {
        std.debug.assert(self.inner.now_ms >= 0);

        return self.speaks();
    }

    /// The language `person` (an account's id) speaks, else the call's: `ctx.locale`.
    pub fn locale_code(self: *const HostApi, person: []const u8) []const u8 {
        std.debug.assert(self.inner.now_ms >= 0);

        if (person.len == 0) {
            return self.speaks();
        }

        return user_language.person_speaks(self.inner, person) catch |err| blk: {
            std.log.warn("ctx.locale: {s}'s language not read: {t}", .{ person, err });
            break :blk self.speaks();
        };
    }

    /// The language the call speaks: the person's, else the variant read.
    fn speaks(self: *const HostApi) []const u8 {
        std.debug.assert(self.inner.now_ms >= 0);

        return self.inner.speaks();
    }

    fn said(
        self: *const HostApi,
        comptime text: []const u8,
        comptime plural: []const u8,
        count: ?u64,
        values: anytype,
    ) []const u8 {
        return self.said_in(self.speaks(), text, plural, count, values);
    }

    pub fn said_in(
        self: *const HostApi,
        code: []const u8,
        comptime text: []const u8,
        comptime plural: []const u8,
        count: ?u64,
        values: anytype,
    ) []const u8 {
        std.debug.assert(text.len > 0);

        const memory = self.inner.arena;
        const fields = @typeInfo(@TypeOf(values)).@"struct".field_names;
        var filled: [fields.len]@import("../context.zig").Message.Value = undefined;

        inline for (fields, &filled) |field_name, *slot| {
            slot.* = .{
                .name = field_name,
                .value = words.shown(memory, @field(values, field_name)) catch "",
            };
        }

        return self.inner.say(code, .{
            .id = text,
            .plural = plural,
            .count = if (count) |number| @floatFromInt(number) else null,
            .values = &filled,
        }) catch text;
    }

    /// Memory of its own for one step of an operation, as the sandboxed `scope` is: from
    /// here until `end`, everything the call allocates and reads is in the scope's memory
    /// (`sdk/plugin_memory.zig`), and `end` gives all of it back. Where the process set no
    /// plugin memory aside, or there is no room, the step works in the memory it began in.
    pub fn scope(self: *HostApi) Scope {
        const outer = self.inner.arena;

        std.debug.assert(self.inner.now_ms >= 0);

        if (self.inner.plugins_set_aside == null) {
            return .{
                .outer = outer,
                .work = null,
            };
        }

        const work = outer.create(plugin_memory.Work) catch {
            return .{
                .outer = outer,
                .work = null,
            };
        };

        work.begin(self.inner);

        return .{
            .outer = outer,
            .work = if (work.own()) work else null,
        };
    }

    pub const Scope = struct {
        outer: std.mem.Allocator,
        work: ?*plugin_memory.Work,

        /// Back to the memory the call had before the scope; what the scope holds stays.
        pub fn leave(self: *Scope) void {
            if (self.work) |work| {
                work.leave();
            }
        }

        /// `text` copied into the memory the call had before the scope: what a step
        /// carries out when it is more than a number.
        pub fn keep(self: *Scope, text: []const u8) error{OutOfMemory}![]const u8 {
            return self.outer.dupe(u8, text);
        }

        /// Everything the scope holds is given back.
        pub fn end(self: *Scope) void {
            const work = self.work orelse return;

            work.end();
            self.work = null;
        }
    };

    pub fn arena(self: *const HostApi) std.mem.Allocator {
        std.debug.assert(self.inner.now_ms >= 0);
        std.debug.assert(self.inner.next_operation_id > 0);

        return self.inner.arena;
    }

    /// Inside an operation, or at the top when an `on` hook hears a queued event.
    pub fn call(self: *HostApi, comptime Operation: type, in: Operation.In) Error!Operation.Out {
        std.debug.assert(self.inner.now_ms >= 0);
        comptime std.debug.assert(registry.SDK.bound(Operation).name.len > 0);

        if (self.reads) |reads| {
            return reads.answer(Operation.Out, comptime registry.SDK.bound(Operation).name, in);
        }

        if (comptime @hasDecl(Operation, "remote")) {
            try remote_reachable(self.inner, Operation.name);
        }

        self.inner.failure = null;

        return in_working_memory(self.inner, comptime registry.SDK.bound(Operation), in);
    }

    /// A call a compiled-in plugin makes, run as an installed plugin's is: in the request's
    /// working memory for nested calls, given back once the answer is copied out. A plugin
    /// making many calls takes the largest one's memory, never the sum. From the caller's
    /// own memory the answer is copied there. From a caller already in the working memory
    /// (its own caller called it) only the call's share is given back, and the answer is
    /// copied to the memory that lasts the top-level call. Run where the caller works
    /// instead when the process set no working memory aside, when nothing lasts the call,
    /// and for an answer that cannot be copied whole (`moved.plain`). An operation whose
    /// work is a plugin's (another plugin's operation) runs in the plugins' own memory
    /// (`in_plugin_memory`), never in core's working memory: a plugin's working data must
    /// not be held to that memory's size.
    fn in_working_memory(
        inner: *sdk.Ctx,
        comptime Bound: type,
        in: Bound.In,
    ) Error!Bound.Out {
        const SDK = registry.SDK;
        const moved = @import("../moved.zig");
        const working_memory = sdk.call_json;

        std.debug.assert(inner.now_ms >= 0);

        if (comptime !moved.plain(Bound.Out)) {
            return SDK.call(inner, Bound, in);
        }

        if (comptime !SDK.core_work(Bound)) {
            return in_plugin_memory(inner, Bound, in);
        }

        const set_aside = inner.calls_set_aside orelse return SDK.call(inner, Bound, in);

        if (set_aside.holds(inner.arena)) {
            const lasting = inner.kept_memory() orelse return SDK.call(inner, Bound, in);
            const begun = set_aside.mark();
            const answer = SDK.call(inner, Bound, in) catch |err| {
                working_memory.give_back(inner, begun);

                return err;
            };
            const kept = moved.copy(Bound.Out, lasting, answer);

            set_aside.rewind(begun);

            return kept;
        }

        var working = try working_memory.Working.begin(inner);
        const result = SDK.call(inner, Bound, in);

        working.end();

        const answer = result catch |err| {
            try working.give_back_failed();

            return err;
        };

        defer working.give_back();

        return moved.copy(Bound.Out, inner.arena, answer);
    }

    /// Another plugin's operation called by a compiled-in plugin: the whole call, the
    /// operation's own work and its hooks', is in memory of its own (`plugin_memory.zig`),
    /// given back once the answer is copied to the caller's. An installed plugin's
    /// operation has its own; a compiled-in one's lies there.
    fn in_plugin_memory(
        inner: *sdk.Ctx,
        comptime Bound: type,
        in: Bound.In,
    ) Error!Bound.Out {
        comptime std.debug.assert(@import("../moved.zig").plain(Bound.Out));
        std.debug.assert(inner.now_ms >= 0);

        var work: plugin_memory.Work = undefined;

        work.begin(inner);

        const result = registry.SDK.call(inner, Bound, in);

        work.leave();
        defer work.end();

        const answer = try result;

        if (!work.own()) {
            return answer;
        }

        return @import("../moved.zig").copy(Bound.Out, inner.arena, answer);
    }

    /// Which refusal the last `ctx.call` came back with as `error.Failed`, or the plugin's
    /// own `fail` named, by its `Fails:` name (`NotEnoughStock`); empty when there was none.
    pub fn failure(self: *const HostApi) []const u8 {
        std.debug.assert(self.inner.now_ms >= 0);

        const found = self.inner.failure orelse return "";

        std.debug.assert(found.name.len > 0);

        return found.name;
    }

    /// A remote operation answers `Unavailable` while it is off: its plugin is not there,
    /// or it does not fit what that plugin is now.
    fn remote_reachable(inner: *const sdk.Ctx, comptime name: []const u8) Error!void {
        const compiled_in = comptime registry.SDK.find(name) != null;

        std.debug.assert(name.len > 0);

        const off = registry.remotes_off;
        const is_off = @import("remote_contract.zig").is_off;

        if (inner.plugin.len > 0 and is_off(off, inner.plugin, name)) {
            return error.Unavailable;
        }

        const sandboxed = inner.sandboxed_plugins orelse {
            return if (compiled_in) {} else error.Unavailable;
        };

        if (inner.plugin.len > 0 and sandboxed.remote_off(inner.plugin, name)) {
            return error.Unavailable;
        }

        if (!compiled_in and sandboxed.find(name) == null) {
            return error.Unavailable;
        }
    }

    /// `mod` for many values at once: a cart's lines, an order's charges. Each modifier
    /// hears them in batches with its reads made together for all, so the cost is one call
    /// per batch, never one per value. Answers them in the same order.
    pub fn mod_all(
        self: *HostApi,
        comptime name: []const u8,
        comptime Value: type,
        values: []const Value,
    ) Error![]const Value {
        comptime {
            if (!mods.valid(name, false)) {
                @compileError("`" ++ name ++ "` is no mod name: dotted parts of a-z, 0-9 and _");
            }
        }

        const memory = self.arena();
        const changed = memory.alloc(Value, values.len) catch return error.OutOfMemory;
        var start: usize = 0;

        while (start < values.len) {
            const end = @min(values.len, start + mods.items_max);
            const batch = values[start..end];
            const made = try self.applied(name, Value, batch);

            @memcpy(changed[start..end], if (made.len == batch.len) made else batch);
            start = end;
        }

        std.debug.assert(changed.len == values.len);

        return changed;
    }

    /// One batch through `mod.apply`: laid out once, held that way through every modifier
    /// (`server/sandboxed_plugins/applied.zig`), read back as `Value`s. No text is written.
    fn applied(
        self: *HostApi,
        comptime name: []const u8,
        comptime Value: type,
        batch: []const Value,
    ) Error![]const Value {
        const held_values = @import("../../server/sandboxed_plugins/applied.zig");
        const inner = self.inner;
        const memory = inner.arena;
        const outer = inner.applying;

        std.debug.assert(batch.len <= mods.items_max);

        // The values laid out, each modifier's copy of them and the apply's own work are
        // in memory of their own, given back once the last values are read back.
        var work: plugin_memory.Work = undefined;

        work.begin(inner);
        defer work.end();

        // Nobody modifies the name: the call is still made, and nothing is laid out.
        var held: []const u8 = if (registry.SDK.modified(inner, name))
            try held_values.from_typed(Value, inner.arena, batch)
        else
            "";

        inner.applying = if (held.len > 0) &held else null;
        defer inner.applying = outer;
        inner.failure = null;

        _ = try registry.SDK.call(inner, comptime registry.SDK.bound(mods.Apply), .{
            .name = name,
            .values = .{
                .text = "[]",
            },
        });

        if (held.len == 0) {
            return batch;
        }

        const moved = @import("../moved.zig");

        // Read back in the work's memory and copied whole to the caller's: what the
        // caller keeps is the values alone, never the piece they were read from.
        if (comptime moved.plain(Value)) {
            const read = try held_values.to_typed(Value, inner.arena, held);

            work.leave();

            return if (work.own()) moved.copy([]const Value, memory, read) else read;
        }

        work.leave();

        // What is read back points into the piece it is read from: that lies with it.
        const last = if (work.own())
            memory.dupe(u8, held) catch return error.OutOfMemory
        else
            held;

        return held_values.to_typed(Value, memory, last);
    }

    /// Calls an operation by a name known only when it runs (a contract's provider), `in`
    /// any struct, the answer read as an `Out`.
    pub fn call_named(
        self: *HostApi,
        comptime Out: type,
        name: []const u8,
        in: anytype,
    ) Error!Out {
        std.debug.assert(name.len > 0);

        const moved = @import("../moved.zig");

        // The input's JSON, the answer's and what reading it takes are in memory of their
        // own: the caller keeps the answer alone, when it can be copied whole.
        var work: plugin_memory.Work = undefined;

        if (comptime moved.plain(Out)) {
            work.begin(self.inner);
        } else {
            work.stay(self.inner);
        }

        defer work.end();

        const input = std.json.Stringify.valueAlloc(self.inner.arena, in, .{}) catch {
            return error.OutOfMemory;
        };
        const output = try self.call_json(name, input);
        const read = std.json.parseFromSliceLeaky(Out, self.inner.arena, output, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return error.Invalid;

        work.leave();

        if (comptime !moved.plain(Out)) {
            return read;
        }

        return if (work.own()) moved.copy(Out, self.inner.arena, read) else read;
    }

    /// Calls an operation by name, JSON in and out, through the same checks: core's own way,
    /// which an installed plugin's module does not have.
    pub fn call_json(self: *HostApi, name: []const u8, input: []const u8) Error![]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.reads == null);

        // The call works in memory of its own, as one by type does: its answer is kept.
        var work: plugin_memory.Work = undefined;

        work.begin(self.inner);

        const result = registry.SDK.call_json(self.inner, name, input);

        work.leave();
        defer work.end();

        const output = try result;

        if (!work.own()) {
            return output;
        }

        return self.inner.arena.dupe(u8, output) catch error.OutOfMemory;
    }

    /// `ctx.call_value`: the value written as JSON for `call_json`, its answer read back.
    pub fn call_value(
        self: *HostApi,
        name: []const u8,
        input: free_value.Value,
    ) Error!free_value.Value {
        const free_json = @import("../free_json.zig");
        const memory = self.inner.arena;

        std.debug.assert(name.len > 0);
        std.debug.assert(self.reads == null);

        const text = free_json.text_of(memory, input) catch |err| return err;
        const output = try self.call_json(name, text);

        return free_json.from_text(memory, output) catch |err| return err;
    }

    /// Emits an event: `ctx.emit(OutOfStock, .{ .variant = ref })`, a type made with
    /// `publr.event.define`, its payload carried as JSON. `after` hooks on it run now, inside
    /// the write (a refusal rolls it back); `on` hooks hear it from the queue once it commits.
    pub fn emit(self: *HostApi, comptime Event: type, payload: Event.Payload) void {
        comptime std.debug.assert(@hasDecl(Event, "publr_event_definition"));
        std.debug.assert(self.inner.now_ms >= 0);

        const name = if (comptime Event.full_name.len > 0)
            Event.full_name
        else
            std.fmt.allocPrint(self.inner.arena, "{s}.{s}", .{
                self.inner.plugin,
                Event.verb,
            }) catch
                return self.refuse_emit();
        const text = std.json.Stringify.valueAlloc(self.inner.arena, payload, .{}) catch
            return self.refuse_emit();

        // A message (`publr.messaging.Email`) needs `messaging.send`; a refused one fails the
        // write.
        if (permission_model.key_for_event(name)) |key| {
            if (held_of_running(self.inner.plugin, key) == null) {
                self.inner.event_refusal = self.inner.event_refusal orelse error.Denied;
                return;
            }
        }

        // An email carrying the site's media: only from a plugin that reads media.
        const messaging = @import("../messaging.zig");

        const others_media = messaging.carries_media(self.inner.arena, name, text) and
            (self.inner.plugin.len == 0 or
                !messaging.carries_own_files_only(self.inner, self.inner.plugin, text));

        if (others_media) {
            if (held_of_running(self.inner.plugin, "media.read") == null) {
                self.inner.event_refusal = self.inner.event_refusal orelse error.Denied;
                return;
            }
        }

        // A message names the plugin that sent it.
        const sent = messaging.signed(self.inner.arena, name, text, self.inner.plugin) catch
            return self.refuse_emit();

        if (self.inner.parent == null) {
            return registry.SDK.emit_alone(self.inner, name, sent);
        }

        self.inner.emit_json(name, sent, true);
    }

    /// An event that could not be written fails the write, as a refused one does.
    fn refuse_emit(self: *HostApi) void {
        self.inner.event_refusal = self.inner.event_refusal orelse error.OutOfMemory;
    }

    /// Refuses the call in the plugin's own words: `return ctx.fail(.NotEnoughStock, "Only
    /// {left} left", .{ .left = left })`. The name is what a form's redirect carries, the
    /// message what a person reads, its status the one the operation's `Fails:` gives.
    pub fn fail(
        self: *HostApi,
        comptime name: @TypeOf(.enum_literal),
        comptime text: []const u8,
        values: anytype,
    ) error{Failed} {
        std.debug.assert(self.inner.now_ms >= 0);
        comptime std.debug.assert(@tagName(name).len > 0);

        const message = self.t(text, values);

        return self.inner.fail(.{
            .name = @tagName(name),
            .status = words.status_of(running_failures(self.inner.within), @tagName(name)),
            .message = words.kept(message),
        });
    }

    /// Refuses the input with every problem `.validate` found, each beside its field.
    pub fn refuse(
        self: *HostApi,
        problems: []const sdk.operation.Problem,
    ) error{ Invalid, OutOfMemory } {
        std.debug.assert(problems.len > 0);
        std.debug.assert(self.inner.now_ms >= 0);

        const kept = try self.inner.arena.dupe(sdk.operation.Problem, problems);

        return self.inner.refuse(kept);
    }

    /// A line in the log, attributed to the plugin and the call: kept with the call's
    /// activity or error entry and on the plugin's Log tab; the server's output outside one.
    pub fn log(
        self: *HostApi,
        comptime level: words.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        comptime std.debug.assert(format.len > 0);
        std.debug.assert(self.inner.now_ms >= 0);

        const line = std.fmt.allocPrint(self.inner.arena, format, args) catch format;
        const plugin = self.inner.plugin;

        if (self.inner.lines) |lines| {
            lines.add(.{
                .plugin = plugin,
                .level = @field(sdk.trail.Level, @tagName(level)),
                .text = line,
            });

            return;
        }

        switch (level) {
            .info => std.log.info("plugin {s}: {s}", .{ plugin, line }),
            .warn => std.log.warn("plugin {s}: {s}", .{ plugin, line }),
            .err => std.log.err("plugin {s}: {s}", .{ plugin, line }),
        }
    }
};

pub fn takes_plugin_ctx(comptime function: anytype) bool {
    comptime {
        const info = @typeInfo(@TypeOf(function));

        std.debug.assert(info == .@"fn");
        std.debug.assert(info.@"fn".param_types.len >= 1);

        return info.@"fn".param_types[0] == *PluginCtx;
    }
}

/// The grant among `asks` for `key`, as asked; null when it asks for none.
pub fn held_in(asks: []const Ask, key: []const u8) ?permission_model.Held {
    std.debug.assert(key.len > 0);
    std.debug.assert(asks.len <= permission_define.asks_max);

    for (asks) |ask| {
        if (std.mem.eql(u8, ask.key, key)) {
            return held_of(&ask);
        }
    }

    return null;
}

/// What the compiled-in plugin `plugin` holds of `key`, as its `.permissions` asked; null
/// when it asked nothing of it, or is no compiled-in plugin. Read from the grants the build
/// worked out once per plugin, never from its declarations in the caller's evaluation.
fn held_of_running(plugin: []const u8, key: []const u8) ?permission_model.Held {
    std.debug.assert(plugin.len <= 64);
    std.debug.assert(key.len > 0);

    for (registry.native_plugins.merged_plugin_grants) |grants| {
        if (!std.mem.eql(u8, grants.name, plugin)) {
            continue;
        }

        for (grants.access.held) |held| {
            if (std.mem.eql(u8, held.key, key)) {
                return held;
            }
        }

        return null;
    }

    return null;
}

test "a compiled-in plugin is granted what it asked for, nothing more" {
    const asks = [_]Ask{.{
        .key = "records.write",
        .records = &.{"products.variant"},
        .reason = "Puts the supplier's new prices in",
    }};
    const write = permission_define.Grant.of("records.write", held_in(&asks, "records.write"));

    try std.testing.expect(write.on and !write.publish);
    try std.testing.expect(!permission_define.Grant.of(
        "records.read",
        held_in(&asks, "records.read"),
    ).on);
    try std.testing.expect(!permission_define.Grant.of(
        "http.fetch",
        held_of_running("no_such_plugin", "http.fetch"),
    ).on);
}

test "a compiled-in plugin's http.fetch grant answers its domains as asked" {
    const asks = [_]Ask{.{
        .key = "http.fetch",
        .domains = &.{ "api.supplier.com", "*.supplier-cdn.com" },
        .reason = "Downloads the supplier's price list",
    }};
    const fetch = permission_define.Grant.of("http.fetch", held_in(&asks, "http.fetch"));

    try std.testing.expect(fetch.on);
    try std.testing.expectEqual(@as(usize, 2), fetch.domains.len);
    try std.testing.expectEqualStrings("*.supplier-cdn.com", fetch.domains[1]);
    try std.testing.expectEqual(@as(usize, 0), permission_define.Grant.off.domains.len);
}

/// The `Fails:` of the compiled-in operation running now; none for any other.
fn running_failures(operation_name: []const u8) []const sdk.operation.Failure {
    std.debug.assert(operation_name.len <= sdk.operation.name_len_max * 2);

    for (declared_failures) |entry| {
        if (std.mem.eql(u8, entry.name, operation_name)) {
            return entry.failures;
        }
    }

    return &.{};
}

const DeclaredFailures = struct {
    name: []const u8,
    failures: []const sdk.operation.Failure,
};

/// Every compiled-in operation declaring failures, with them: built once, read by name.
const declared_failures: []const DeclaredFailures = table: {
    const operations = registry.SDK.operations;

    // A few branches an operation, once: the budget grows with the list.
    @setEvalBranchQuota(1000 + operations.len * 32);

    var count: u32 = 0;

    for (operations) |Operation| {
        if (@hasDecl(Operation, "failures")) {
            count += 1;
        }
    }

    var entries: [count]DeclaredFailures = undefined;
    var index: u32 = 0;

    for (operations) |Operation| {
        if (@hasDecl(Operation, "failures")) {
            entries[index] = .{
                .name = Operation.name,
                .failures = words.failures_of(Operation),
            };
            index += 1;
        }
    }

    const done = entries;

    break :table &done;
};

test "ctx.failure() names the refusal a call came back with" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var inner = harness.ctx(.system);
    var ctx: HostApi = .{
        .inner = &inner,
    };

    try std.testing.expectEqualStrings("", ctx.failure());
    const refused: error{Failed}!void = inner.fail(.{
        .name = "NotEnoughStock",
        .status = 409,
        .message = "Only 2 left",
    });

    try std.testing.expectError(error.Failed, refused);
    try std.testing.expectEqualStrings("NotEnoughStock", ctx.failure());
}
