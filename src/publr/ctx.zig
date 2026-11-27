//! `publr.Ctx`: what a plugin's operations and hooks run with, declared once. A plugin built
//! into Publr and one installed into the sandbox take the same `*publr.Ctx` and make the
//! same calls: compiled in, each call goes straight to Publr; installed, each is a message
//! to the host. A plugin never makes one: Publr hands it over, and what lies behind it is
//! Publr's own.
const std = @import("std");
const guest = @import("../sdk/plugin/guest.zig");
const words = @import("plugin/words.zig");
const caller_view = @import("caller.zig");
const permission_define = @import("../sdk/plugin/permission_define.zig");
const calls = @import("ctx/calls.zig");
const free_value = @import("free_value.zig");
const operation = @import("operation.zig");
// Until `publr.Error` is the public set: an operation's errors, database ones among them.
const Error = @import("../sdk/operation.zig").Error;

/// What lies behind a `Ctx` in this build: the call's state in the host, or in the module.
const Behind = switch (guest.mode) {
    .sandboxed => guest.SandboxApi,
    .native => @import("../sdk/plugin/context.zig").HostApi,
};

fn BehindOf(comptime Pointer: type) type {
    return if (@typeInfo(Pointer).pointer.attrs.@"const") *const Behind else *Behind;
}

fn behind(ctx: anytype) BehindOf(@TypeOf(ctx)) {
    return @ptrCast(@alignCast(ctx));
}

fn PluginState(comptime Plugin: type) type {
    return @import("../server/plugin_states.zig").StateOf(Plugin);
}

pub const Ctx = opaque {
    pub const Scope = ScopeOf;
    pub const Locale = LocaleOf;

    /// Who is calling: where from, whether signed in, their account and roles, whether an
    /// administrator granted them this operation, the visitor's stable id.
    pub fn caller(ctx: *const Ctx) caller_view.View {
        return behind(ctx).caller();
    }

    /// What the plugin was given for a request. Compiled in: what its `.permissions` asked
    /// for. Installed: whether an administrator granted the key now, and its flags.
    pub fn grant(ctx: *const Ctx, comptime key: []const u8) permission_define.Grant {
        return behind(ctx).grant(key);
    }

    /// The call's time, one value for the whole call.
    pub fn now(ctx: *const Ctx) words.Time {
        return behind(ctx).now();
    }

    pub const holds_until = calls.holds_until;
    pub const sign = calls.sign;
    pub const verify = calls.verify;
    pub const make_file = calls.make_file;
    pub const random = calls.random;
    pub const time_zone = calls.time_zone;

    /// The same plugin, calling for one person: every call made through the answer runs as
    /// the plugin acting for the account `person` (its id), with the plugin's own grants, so
    /// a record it makes names them as its maker and the site's policies judge the person.
    /// For a built-in plugin's operations that read and write on a member's behalf after
    /// checking what is theirs: an installed build that asks for it does not compile.
    pub fn as_person(ctx: *Ctx, person: []const u8) Error!*Ctx {
        if (comptime guest.mode == .sandboxed) {
            @compileError("ctx.as_person() is for a built-in plugin's own operations");
        }

        return behind(ctx).as_person(person);
    }

    /// Whether the caller (the person, through `as_person`) may run `Operation`, as the
    /// call itself would be judged: to offer only what they may do. An installed build that
    /// asks for it does not compile.
    pub fn may(ctx: *const Ctx, comptime Operation: type) bool {
        if (comptime guest.mode == .sandboxed) {
            @compileError("ctx.may() is for a built-in plugin's own code");
        }

        return behind(ctx).may(Operation);
    }

    /// Queues `Job` to run after this call, between requests, as the plugin. Inside a write,
    /// a rolled-back write queues nothing: `try ctx.enqueue(ReleaseHold, .{ .hold = ref })`.
    pub fn enqueue(ctx: *Ctx, comptime Job: type, in: Job.Input) Error!void {
        return ctx.enqueue_at(Job, in, ctx.now());
    }

    /// `enqueue` with when it may run: never before `at`, about a minute after it at most.
    pub fn enqueue_at(ctx: *Ctx, comptime Job: type, in: Job.Input, at: words.Time) Error!void {
        return behind(ctx).enqueue_at(Job, in, at);
    }

    /// SQL on the plugin's own tables (`host.table`), inside the call's transaction. Only a
    /// plugin with `.extend` has tables, so only a compiled-in one: an installed build that
    /// asks for it does not compile.
    pub fn database(ctx: *const Ctx) @import("extend/database.zig").Database {
        if (comptime guest.mode == .sandboxed) {
            @compileError("ctx.database() is for a built-in plugin's own tables (`.extend`)");
        }

        return behind(ctx).database();
    }

    /// The state a built-in plugin keeps for the life of the process (`host.state`): an
    /// installed build that asks for it does not compile.
    pub fn state(ctx: *const Ctx, comptime Plugin: type) *PluginState(Plugin) {
        if (comptime guest.mode == .sandboxed) {
            @compileError("ctx.state() is for a built-in plugin's own state (`.extend`)");
        }

        const states = @import("../server/plugin_states.zig");

        return states.of(behind(ctx).inner, Plugin);
    }

    /// Memory freed when the call ends.
    pub fn alloc(ctx: *const Ctx, comptime Item: type, count: u32) error{OutOfMemory}![]Item {
        return behind(ctx).alloc(Item, count);
    }

    /// Formatted text in memory freed when the call ends.
    pub fn print(
        ctx: *const Ctx,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        return behind(ctx).print(format, args);
    }

    /// The call's memory, freed when it ends.
    pub fn arena(ctx: *const Ctx) std.mem.Allocator {
        return behind(ctx).arena();
    }

    /// Text for people, in the caller's language, each `{name}` filled from `values`.
    pub fn t(ctx: *const Ctx, comptime text: []const u8, values: anytype) []const u8 {
        return behind(ctx).t(text, values);
    }

    /// The same for a count: `ctx.tn("{count} item", "{count} items", count, .{ .count = count })`.
    pub fn tn(
        ctx: *const Ctx,
        comptime one: []const u8,
        comptime many: []const u8,
        count: u64,
        values: anytype,
    ) []const u8 {
        return behind(ctx).tn(one, many, count, values);
    }

    /// Words marked where they were written (`publr.t`, `ctx.t`) and kept as written: a
    /// label another plugin registered or stored (a line's work, `To send`), in the
    /// caller's language when shown. The text itself where no language pack has it.
    pub fn translate(ctx: *const Ctx, text: []const u8) []const u8 {
        return behind(ctx).translate(text);
    }

    /// The language the call speaks (`pl`, `en`): what `t` answers in.
    pub fn language(ctx: *const Ctx) []const u8 {
        return behind(ctx).language();
    }

    /// Text for one person, in their own language, else the site's: a message composed in
    /// its recipient's words, `const localize = ctx.locale(person); localize.t(…)`. `person`
    /// is the account's id; empty (a guest with no account) keeps the call's language.
    pub fn locale(ctx: *const Ctx, person: []const u8) LocaleOf {
        return .{
            .ctx = ctx,
            .code = behind(ctx).locale_code(person),
        };
    }

    /// Memory of its own for one step of an operation. From here until `end`, everything the
    /// call allocates and reads (`ctx.arena()`, records, answers) is in the scope's memory,
    /// and `end` gives all of it back: an operation then takes the memory of its largest
    /// step, never the sum of its steps. Nothing made inside may be used after `end`; a
    /// number or an enum is carried out by value, anything else is copied into memory taken
    /// before the scope (`keep`). Where there is no room, the step works in the memory it
    /// began in.
    ///
    ///     var step = ctx.scope();
    ///     defer step.end();
    ///
    /// `leave` goes back to the operation's memory while what the scope holds stays readable
    /// until `end`: for something read once and used across later steps.
    pub fn scope(ctx: *Ctx) ScopeOf {
        const outer = ctx.arena();
        const held = outer.create(Behind.Scope) catch {
            return .{
                .outer = outer,
                .held = null,
            };
        };

        held.* = behind(ctx).scope();

        std.debug.assert(held.outer.ptr == outer.ptr);

        return .{
            .outer = outer,
            .held = held,
        };
    }

    /// Runs `Operation` as this plugin, with its grants: another plugin's, core's, or one of
    /// its own. `error.Denied` when an administrator has not granted (or has revoked) what it
    /// needs; `error.Failed` with `failure()` naming a refusal the operation declares.
    pub fn call(ctx: *Ctx, comptime Operation: type, in: Operation.In) Error!Operation.Out {
        return behind(ctx).call(Operation, in);
    }

    /// Calls an operation by a name known only when it runs (a contract's provider), `in`
    /// any struct, the answer read as an `Out`.
    pub fn call_named(ctx: *Ctx, comptime Out: type, name: []const u8, in: anytype) Error!Out {
        return behind(ctx).call_named(Out, name, in);
    }

    /// Calls an operation by name with a value whose shape comes with the data, and answers
    /// one: for a caller that learns what to send only when it runs.
    pub fn call_value(ctx: *Ctx, name: []const u8, input: free_value.Value) Error!free_value.Value {
        return behind(ctx).call_value(name, input);
    }

    /// Which refusal the last `call` came back with as `error.Failed`, or the plugin's own
    /// `fail` named, by its `Fails:` name (`NotEnoughStock`); empty when there was none.
    pub fn failure(ctx: *const Ctx) []const u8 {
        return behind(ctx).failure();
    }

    /// Passes `value` through every modifier of `name` (`publr.modify(name, …)` in any
    /// plugin) and answers what they made of it; with none, the value as it went.
    pub fn mod(ctx: *Ctx, comptime name: []const u8, value: anytype) Error!@TypeOf(value) {
        const changed = try ctx.mod_all(name, @TypeOf(value), &.{value});

        std.debug.assert(changed.len == 1);

        return changed[0];
    }

    /// `mod` for many values at once: a cart's lines, an order's charges. Each modifier
    /// hears them in batches with its reads made together for all, so the cost is one call
    /// per batch, never one per value. Answers them in the same order.
    pub fn mod_all(
        ctx: *Ctx,
        comptime name: []const u8,
        comptime Value: type,
        values: []const Value,
    ) Error![]const Value {
        return behind(ctx).mod_all(name, Value, values);
    }

    /// Emits an event: `ctx.emit(OutOfStock, .{ .variant = ref })`, a type made with
    /// `publr.event.define`. `after` hooks on it run now, inside the write (a refusal rolls
    /// it back); `on` hooks hear it from the queue once it commits.
    pub fn emit(ctx: *Ctx, comptime Event: type, payload: Event.Payload) void {
        behind(ctx).emit(Event, payload);
    }

    /// Refuses the call in the plugin's own words: `return ctx.fail(.NotEnoughStock, "Only
    /// {left} left", .{ .left = left })`. The name is what a form's redirect carries, the
    /// message what a person reads, its status the one the operation's `Fails:` gives.
    pub fn fail(
        ctx: *Ctx,
        comptime name: @TypeOf(.enum_literal),
        comptime text: []const u8,
        values: anytype,
    ) error{Failed} {
        return behind(ctx).fail(name, text, values);
    }

    /// Refuses the input with every problem `.validate` found, each beside its field.
    pub fn refuse(
        ctx: *Ctx,
        problems: []const operation.Problem,
    ) error{ Invalid, OutOfMemory } {
        return behind(ctx).refuse(problems);
    }

    /// A line in the log, attributed to the plugin and the call: kept with the call's
    /// activity or error entry and on the plugin's Log tab; the server's output outside one.
    pub fn log(
        ctx: *Ctx,
        comptime level: words.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        behind(ctx).log(level, format, args);
    }
};

/// `ctx.locale(person)`: `t` and `tn` in one person's language.
const LocaleOf = struct {
    ctx: *const Ctx,
    /// The language they speak (`pl`, `en`).
    code: []const u8,

    pub fn t(self: LocaleOf, comptime text: []const u8, values: anytype) []const u8 {
        return behind(self.ctx).said_in(self.code, text, "", null, values);
    }

    pub fn tn(
        self: LocaleOf,
        comptime one: []const u8,
        comptime many: []const u8,
        count: u64,
        values: anytype,
    ) []const u8 {
        return behind(self.ctx).said_in(self.code, one, many, count, values);
    }
};

/// `ctx.scope()`: one step's memory, given back at `end`.
const ScopeOf = struct {
    /// The memory the call had before the scope.
    outer: std.mem.Allocator,
    /// Publr's own; null when there was no room and the step works in `outer`.
    held: ?*anyopaque,

    fn state(self: *ScopeOf) ?*Behind.Scope {
        const held = self.held orelse return null;

        return @ptrCast(@alignCast(held));
    }

    /// Back to the memory the call had before the scope; what the scope holds stays.
    pub fn leave(self: *ScopeOf) void {
        if (self.state()) |held| {
            held.leave();
        }
    }

    /// `text` copied into the memory the call had before the scope: what a step carries out
    /// when it is more than a number.
    pub fn keep(self: *ScopeOf, text: []const u8) error{OutOfMemory}![]const u8 {
        return self.outer.dupe(u8, text);
    }

    /// Everything the scope holds is given back.
    pub fn end(self: *ScopeOf) void {
        const held = self.state() orelse return;

        held.end();
        self.held = null;
    }
};
