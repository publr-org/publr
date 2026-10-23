const std = @import("std");
const mods = @import("../mods.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const words = @import("words.zig");
const permission_define = @import("permission_define.zig");
const plugin_define = @import("define.zig");
const Ask = @import("../../model/sandboxed_plugin.zig").Ask;
const caller_view = @import("caller_view.zig");
const role = @import("../../model/role.zig");
const job_define = @import("job_define.zig");
const job_queue = @import("../../store/job_queue.zig");
const permission_model = @import("../../model/permission.zig");
const language = @import("../../operations/user/language.zig");

pub const Caller = sdk.Caller;
pub const Error = sdk.Error;

/// What a plugin's operations and hooks take: `SandboxApi` when the plugin is loaded into
/// the sandbox (every call proxied to the host), `HostApi` when it is built in (direct calls,
/// full access). The same source compiles either way.
pub const PluginCtx = switch (guest.mode) {
    .sandboxed => guest.SandboxApi,
    .native => HostApi,
};

pub const Mode = guest.Mode;

const guest = @import("guest.zig");
const mod_reads = @import("mod_reads.zig");

/// A native plugin's way into Publr: direct calls through the SDK, full access.
pub const HostApi = struct {
    inner: *sdk.Ctx,
    /// Set while a modifier runs: its reads are noted and answered for the whole batch.
    reads: ?*mod_reads.Reads = null,

    /// Who is calling: where from, whether signed in, their roles, whether an
    /// administrator granted them this operation, the visitor's stable id.
    pub fn caller(self: *const PluginCtx) caller_view.View {
        std.debug.assert(self.inner.now_ms >= 0);
        std.debug.assert(self.inner.next_operation_id > 0);

        const through_app = self.inner.app_plugins != null;
        const raw = self.inner.caller;
        const granted_here = !through_app and self.inner.within.len > 0 and
            granted_by_role(self.inner, self.inner.within);

        return .{
            .from = caller_view.from_of(raw, through_app, self.inner.over_api, self.inner.job),
            .visitor = self.inner.visitor,
            .referer = self.inner.referer,
            .raw = raw,
            .granted_here = granted_here,
        };
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
    pub fn grant(self: *const PluginCtx, comptime key: []const u8) permission_define.Grant {
        std.debug.assert(self.inner.now_ms >= 0);

        return permission_define.Grant.of(key, held_in(asks_of_running(self.inner.plugin), key));
    }

    /// The call's time, one value for the whole call.
    pub fn now(self: *const PluginCtx) words.Time {
        std.debug.assert(self.inner.now_ms >= 0);

        return .{
            .ms = self.inner.now_ms,
        };
    }

    /// Queues `Job` to run after this call, between requests, as the plugin. Inside a write,
    /// a rolled-back write queues nothing: `try ctx.enqueue(ReleaseHold, .{ .hold = ref })`.
    pub fn enqueue(self: *PluginCtx, comptime Job: type, in: Job.Input) Error!void {
        std.debug.assert(self.inner.now_ms >= 0);
        comptime std.debug.assert(job_define.is_job(Job));

        return self.enqueue_at(Job, in, self.now());
    }

    /// `enqueue` with when it may run: never before `at`, about a minute after it at most.
    pub fn enqueue_at(
        self: *PluginCtx,
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
    pub fn database(self: *const PluginCtx) @import("host.zig").Database {
        std.debug.assert(self.inner.now_ms >= 0);

        return .{
            .connection = self.inner.db,
        };
    }

    /// Memory freed when the call ends.
    pub fn alloc(
        self: *const PluginCtx,
        comptime Item: type,
        count: u32,
    ) error{OutOfMemory}![]Item {
        std.debug.assert(count <= 1 << 24);

        return self.inner.arena.alloc(Item, count);
    }

    /// Formatted text in memory freed when the call ends.
    pub fn print(
        self: *const PluginCtx,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        comptime std.debug.assert(format.len > 0);

        return std.fmt.allocPrint(self.inner.arena, format, args);
    }

    /// Text for people, in the caller's language, each `{name}` filled from `values`.
    pub fn t(self: *const PluginCtx, comptime text: []const u8, values: anytype) []const u8 {
        comptime std.debug.assert(text.len > 0);

        return self.said(text, "", null, values);
    }

    /// The same for a count: `ctx.tn("{count} item", "{count} items", count, .{ .count = count })`.
    pub fn tn(
        self: *const PluginCtx,
        comptime one: []const u8,
        comptime many: []const u8,
        count: u64,
        values: anytype,
    ) []const u8 {
        comptime std.debug.assert(one.len > 0 and many.len > 0);

        return self.said(one, many, count, values);
    }

    /// Text for one person, in their own language, else the site's: a message composed in
    /// its recipient's words, `const localize = ctx.locale(person); localize.t(…)`. `person`
    /// is the account's id; empty (a guest with no account) keeps the call's language.
    pub fn locale(self: *const PluginCtx, person: []const u8) Locale {
        std.debug.assert(self.inner.now_ms >= 0);

        if (person.len == 0) {
            return .{
                .ctx = self,
                .locale = self.speaks(),
            };
        }

        const chosen = language.person_speaks(self.inner, person) catch |err| blk: {
            std.log.warn("ctx.locale: {s}'s language not read: {t}", .{ person, err });
            break :blk self.speaks();
        };

        return .{
            .ctx = self,
            .locale = chosen,
        };
    }

    /// `ctx.locale(person)`: `t` and `tn` in one person's language.
    pub const Locale = struct {
        ctx: *const PluginCtx,
        locale: []const u8,

        pub fn t(self: Locale, comptime text: []const u8, values: anytype) []const u8 {
            comptime std.debug.assert(text.len > 0);

            return self.ctx.said_in(self.locale, text, "", null, values);
        }

        pub fn tn(
            self: Locale,
            comptime one: []const u8,
            comptime many: []const u8,
            count: u64,
            values: anytype,
        ) []const u8 {
            comptime std.debug.assert(one.len > 0 and many.len > 0);

            return self.ctx.said_in(self.locale, one, many, count, values);
        }
    };

    /// The language the call speaks: the person's, else the variant read.
    fn speaks(self: *const PluginCtx) []const u8 {
        std.debug.assert(self.inner.now_ms >= 0);

        return if (self.inner.language.locale.len > 0)
            self.inner.language.locale
        else
            self.inner.variant;
    }

    fn said(
        self: *const PluginCtx,
        comptime text: []const u8,
        comptime plural: []const u8,
        count: ?u64,
        values: anytype,
    ) []const u8 {
        return self.said_in(self.speaks(), text, plural, count, values);
    }

    fn said_in(
        self: *const PluginCtx,
        locale_code: []const u8,
        comptime text: []const u8,
        comptime plural: []const u8,
        count: ?u64,
        values: anytype,
    ) []const u8 {
        std.debug.assert(text.len > 0);

        const memory = self.inner.arena;
        const fields = std.meta.fields(@TypeOf(values));
        var filled: [fields.len]@import("../context.zig").Message.Value = undefined;

        inline for (fields, &filled) |field, *slot| {
            slot.* = .{
                .name = field.name,
                .value = words.shown(memory, @field(values, field.name)) catch "",
            };
        }

        return self.inner.say(locale_code, .{
            .id = text,
            .plural = plural,
            .count = if (count) |number| @floatFromInt(number) else null,
            .values = &filled,
        }) catch text;
    }

    pub fn arena(self: *const PluginCtx) std.mem.Allocator {
        std.debug.assert(self.inner.now_ms >= 0);
        std.debug.assert(self.inner.next_operation_id > 0);

        return self.inner.arena;
    }

    /// Inside an operation, or at the top when an `on` hook hears a queued event.
    pub fn call(self: *PluginCtx, comptime Operation: type, in: Operation.In) Error!Operation.Out {
        std.debug.assert(self.inner.now_ms >= 0);
        comptime std.debug.assert(registry.SDK.bound(Operation).name.len > 0);

        if (self.reads) |reads| {
            return reads.answer(Operation.Out, comptime registry.SDK.bound(Operation).name, in);
        }

        if (comptime @hasDecl(Operation, "remote")) {
            try remote_reachable(self.inner, Operation.name);
        }

        self.inner.failure = null;

        return registry.SDK.call(self.inner, comptime registry.SDK.bound(Operation), in);
    }

    /// Which refusal the last `ctx.call` came back with as `error.Failed`, or the plugin's
    /// own `fail` named, by its `Fails:` name (`NotEnoughStock`); empty when there was none.
    pub fn failure(self: *const PluginCtx) []const u8 {
        std.debug.assert(self.inner.now_ms >= 0);

        const found = self.inner.failure orelse return "";

        std.debug.assert(found.name.len > 0);

        return found.name;
    }

    /// A remote operation answers `Unavailable` while it is off: its plugin is not there,
    /// or it does not fit what that plugin is now.
    fn remote_reachable(inner: *const sdk.Ctx, comptime name: []const u8) Error!void {
        const compiled_in = comptime for (registry.SDK.operations) |Candidate| {
            if (std.mem.eql(u8, Candidate.name, name)) {
                break true;
            }
        } else false;

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

    /// Passes `value` through every modifier of `name` (`publr.modify(name, …)` in any
    /// plugin) and answers what they made of it; with none, the value as it went.
    pub fn mod(self: *PluginCtx, comptime name: []const u8, value: anytype) Error!@TypeOf(value) {
        comptime {
            if (!mods.valid(name, false)) {
                @compileError("`" ++ name ++ "` is no mod name: dotted parts of a-z, 0-9 and _");
            }
        }

        const Value = @TypeOf(value);
        const values: []const Value = &.{value};
        const memory = self.arena();
        const text = std.json.Stringify.valueAlloc(memory, values, .{}) catch {
            return error.OutOfMemory;
        };
        const answered = try self.call(mods.Apply, .{
            .name = name,
            .values = text,
        });

        const changed = std.json.parseFromSliceLeaky([]const Value, memory, answered.values, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch return value;

        return if (changed.len == 1) changed[0] else value;
    }

    /// Calls an operation by name, JSON in and out, through the same checks.
    pub fn call_json(self: *PluginCtx, name: []const u8, input: []const u8) Error![]const u8 {
        std.debug.assert(name.len > 0);
        std.debug.assert(self.reads == null);

        return registry.SDK.call_json(self.inner, name, input);
    }

    /// Emits an event: `ctx.emit(OutOfStock, .{ .variant = ref })`, a type made with
    /// `publr.event.define`, its payload carried as JSON. `after` hooks on it run now, inside
    /// the write (a refusal rolls it back); `on` hooks hear it from the queue once it commits.
    pub fn emit(self: *PluginCtx, comptime Event: type, payload: Event.Payload) void {
        comptime std.debug.assert(@hasDecl(Event, "publr_event_definition"));
        std.debug.assert(self.inner.parent != null);

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
            if (held_in(asks_of_running(self.inner.plugin), key) == null) {
                self.inner.event_refusal = self.inner.event_refusal orelse error.Denied;
                return;
            }
        }

        self.inner.emit_json(name, text, true);
    }

    /// An event that could not be written fails the write, as a refused one does.
    fn refuse_emit(self: *PluginCtx) void {
        self.inner.event_refusal = self.inner.event_refusal orelse error.OutOfMemory;
    }

    /// Refuses the call in the plugin's own words: `return ctx.fail(.NotEnoughStock, "Only
    /// {left} left", .{ .left = left })`. The name is what a form's redirect carries, the
    /// message what a person reads, its status the one the operation's `Fails:` gives.
    pub fn fail(
        self: *PluginCtx,
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
        self: *PluginCtx,
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
        self: *PluginCtx,
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
        std.debug.assert(info.@"fn".params.len >= 1);

        return info.@"fn".params[0].type == *PluginCtx;
    }
}

/// The grant among `asks` for `key`, as asked; null when it asks for none.
pub fn held_in(asks: []const Ask, key: []const u8) ?permission_model.Held {
    std.debug.assert(key.len > 0);
    std.debug.assert(asks.len <= permission_define.asks_max);

    for (asks) |ask| {
        if (std.mem.eql(u8, ask.key, key)) {
            return ask.held();
        }
    }

    return null;
}

/// What the compiled-in plugin `plugin` asked for in its `.permissions`; nothing for any other.
fn asks_of_running(plugin: []const u8) []const Ask {
    std.debug.assert(plugin.len <= 64);

    inline for (registry.native_plugins.all) |Plugin| {
        if (std.mem.eql(u8, Plugin.manifest.name, plugin)) {
            if (comptime !plugin_define.has(Plugin, "permissions")) {
                return &.{};
            }

            return comptime plugin_define.get(Plugin, "permissions");
        }
    }

    return &.{};
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
        held_in(asks_of_running("no_such_plugin"), "http.fetch"),
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

    inline for (registry.SDK.operations) |Operation| {
        if (comptime @hasDecl(Operation, "failures")) {
            if (std.mem.eql(u8, Operation.name, operation_name)) {
                return comptime words.failures_of(Operation);
            }
        }
    }

    return &.{};
}

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
