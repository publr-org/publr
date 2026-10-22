const std = @import("std");
const db = @import("../lib/db.zig");
const Caller = @import("caller.zig").Caller;
const AuthState = @import("../lib/auth.zig").State;
const Emitted = @import("middleware.zig").Event.Emitted;
const Scratch = @import("scratch.zig").Scratch;
const DefinitionCache = @import("definition_cache.zig").DefinitionCache;

pub const OperationId = u64;

/// Where an emitted event goes: `after` hooks by name when `after` (a plugin's event, core's
/// typed ones), then the queue for the `on` hooks.
pub const Notify = *const fn (ctx: *Ctx, emitted: Emitted, after: bool) void;

/// Builds a sandboxed plugin from its sources in the project, in a process of its own (the
/// server answers on meanwhile), then installs it: what `plugin build` starts for an agent.
pub const PluginBuilder = struct {
    context: *anyopaque,
    /// Where each plugin's sources are: `<plugins_dir>/<name>/`.
    plugins_dir: []const u8,
    /// Where each build writes what it did: `<logs_dir>/<name>.log`.
    logs_dir: []const u8,
    /// Starts the build: null once started, else why it could not be.
    start: *const fn (context: *anyopaque, name: []const u8) ?[]const u8,
};

/// Starts a conversation's turn in a process of its own beside the server (`publr agent`),
/// which asks the server for its device and reports each step back.
pub const AgentStarter = struct {
    context: *anyopaque,
    /// Starts the turn: null once started, else why it could not be.
    start: *const fn (context: *anyopaque, conversation_id: []const u8) ?[]const u8,
};

/// Where a model's words go as a provider plugin streams them (`ai.progress`): the agent
/// running the turn.
pub const Progress = struct {
    context: *anyopaque,
    said: *const fn (context: *anyopaque, words: []const u8) void,
};

/// Told when a conversation changes (a step, the words so far, its end), so the pages
/// watching it hear at once: `serve`'s open workspaces.
pub const Live = struct {
    context: *anyopaque,
    changed: *const fn (context: *anyopaque, conversation_id: []const u8) void,
};

/// Updating this site's Publr, where `serve` runs it: one release fetched, checked and
/// rehearsed in a process of its own, then swapped in and restarted (`server/update.zig`).
pub const Updater = struct {
    context: *anyopaque,
    /// Whoever runs this site keeps its Publr up to date (Publr Cloud): nothing here starts
    /// an update, and the admin says so.
    managed: bool,
    /// Starts `action`: null once started, else why it could not be.
    start: *const fn (context: *anyopaque, action: UpdateAction, version: []const u8) ?[]const u8,
    /// What the last update did, and what can be done now.
    status: *const fn (context: *anyopaque, arena: std.mem.Allocator) UpdateStatus,
    /// The releases newer than this one as the last look found them; a new look starts in
    /// the background when that one is over a minute old (`update-run --look`).
    releases: *const fn (context: *anyopaque, arena: std.mem.Allocator) Releases,
};

pub const Releases = struct {
    releases: []const @import("../model/release.zig").Release = &.{},
    /// A look is on its way: ask again for what it finds.
    looking: bool = false,
    /// Why the last look failed; empty when it answered.
    problem: []const u8 = "",
};

pub const UpdateAction = enum { apply, rollback };

pub const UpdateStatus = struct {
    /// `idle`, or the step an update is on: `downloading`, `verifying`, `rehearsing`,
    /// `swapping`, `restarting`; `done` or `failed` once over.
    step: []const u8 = "idle",
    /// What it is updating to (or rolling back to).
    target: []const u8 = "",
    /// Why it failed, or what it did.
    message: []const u8 = "",
    /// The release this one replaced, when its binary is kept to roll back to.
    previous: ?[]const u8 = null,
    /// The backups taken before updates, newest first.
    backups: []const UpdateBackup = &.{},
};

pub const UpdateBackup = struct {
    name: []const u8,
    /// The release that last opened the site before; empty when none recorded one.
    from: []const u8,
    to: []const u8,
    at_ms: i64,
};

/// The disagreements between installed translations, worked out once when the server
/// started (and again when picks change): what Site Health lists.
pub const Translations = struct {
    context: *const anyopaque,
    /// Each language's disagreements.
    disagreements: *const fn (context: *const anyopaque) []const LanguageDisagreements,
    /// How much of each domain's messages each language covers.
    coverage: *const fn (context: *const anyopaque) []const Coverage,
    /// A message in `locale`, its values filled: the source text when no plugin translates
    /// it there.
    say: *const fn (
        context: *const anyopaque,
        arena: std.mem.Allocator,
        locale: []const u8,
        message: Message,
    ) std.mem.Allocator.Error![]const u8,
};

/// The source text with each `{name}` its value, the plural by count: what `Ctx.say` gives
/// where no server built the languages.
fn filled(arena: std.mem.Allocator, message: Message) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(message.id.len > 0);

    const many = message.plural.len > 0 and message.count != null and message.count.? != 1;
    var text: []const u8 = if (many) message.plural else message.id;

    for (message.values) |value| {
        const hole = try std.mem.concat(arena, u8, &.{ "{", value.name, "}" });

        text = try std.mem.replaceOwned(u8, arena, text, hole, value.value);
    }

    std.debug.assert(text.len > 0 or message.values.len > 0);

    return text;
}

/// What plugin code says to people outside the admin, an email or a page of its own, in the
/// words of the language it names (`Ctx.say`).
pub const Message = struct {
    context: []const u8 = "",
    id: []const u8,
    /// The source's plural (`{count} projects`), empty for a message without one.
    plural: []const u8 = "",
    count: ?f64 = null,
    values: []const Value = &.{},

    pub const Value = struct {
        name: []const u8,
        value: []const u8,
    };
};

/// One language over one domain's messages: how many it translates, the ones it does not,
/// and the plugins that bring its translations of them.
pub const Coverage = struct {
    locale: []const u8,
    label: []const u8,
    domain: []const u8,
    translated: u32,
    total: u32,
    missing: []const MessageId,
    providers: []const []const u8,
};

pub const MessageId = struct {
    context: []const u8,
    id: []const u8,
};

pub const Language = struct {
    locale: []const u8 = "",
    /// The render's `Translator` (`publr_translations`), null for English.
    translator: ?*const anyopaque = null,
    /// The catalogue as the script the browser and the render's engine read.
    catalogue: []const u8 = "",
};

pub const LanguageDisagreements = struct {
    locale: []const u8,
    label: []const u8,
    conflicts: []const @import("../model/i18n/conflicts.zig").Conflict,
};

/// The folder the running server reads the project's apps from, and a way to read them
/// again: what the `apps` operations change.
pub const AppsFolder = struct {
    context: *anyopaque,
    dir: []const u8,
    /// The apps read again and swapped in: null when they load, else why they do not.
    reload: *const fn (context: *anyopaque) ?[]const u8,
};

pub const Ctx = struct {
    dependency_failure: bool = false,

    /// Why the last operation ended with `error.Failed`: set by `fail`, read by adapters.
    failure: ?@import("operation.zig").Failure = null,
    /// What was wrong with the input when it ended with `error.Invalid`, every field at
    /// once: set by `refuse`, answered as `problems`.
    problems: []const @import("operation.zig").Problem = &.{},
    caller: Caller,
    /// Reads made to render a page for a visitor: live records only and never a write,
    /// whoever the caller is, so a signed-in visitor never sees a draft on the site.
    delivery: bool = false,
    /// Reads made to draw a preview of the site: never a write, and every record read is its
    /// edit copy (pending changes, else the record as saved), drafts included, never the
    /// trash, so the site reads as it will once everything edited is published.
    preview: bool = false,
    /// The variant a page for a visitor or a preview reads documents in (a language code, set
    /// from the address by the plugin that declares the dimension); empty: the main values.
    variant: []const u8 = "",
    /// The app a request came through (`app.zon`'s `.name`), empty for the admin, the CLI and
    /// the API: a document created on the way belongs to it.
    app: []const u8 = "",
    /// The visitor's stable id (the `publr_visitor` cookie) when the call came from an app's
    /// page, island or `/_actions`; empty otherwise. Beside the user once they sign in.
    visitor: []const u8 = "",
    /// The address the request came from (`limits.address_of`); empty for a context no
    /// request made, which no rate limit counts.
    address: []const u8 = "",
    /// The page that sent the request when it is another site's (the `Referer` header);
    /// empty for our own pages and a request that names none. Tells, never grants.
    referer: []const u8 = "",
    /// The process's rate limits; null where calls are not limited (the CLI on its own,
    /// tests, the browser build).
    limits: ?*@import("limits.zig").Limits = null,
    /// Where the caller stands against the limit that answered last: the `RateLimit-*`
    /// headers. Set once the context counted its first call.
    rate: ?@import("limits.zig").Outcome = null,
    /// The context counted its first top-level call against the general limit: one request
    /// counts once, however many calls it makes.
    counted: bool = false,
    /// The plugins whose content types the caller may reach here: an app's `.plugins`, or
    /// the admin narrowed to that app. Null: every plugin's.
    app_plugins: ?[]const []const u8 = null,
    /// The app whose types the caller reaches here: those living in it or shared with it.
    /// The app a request came through, or the one the admin is narrowed to; empty: every
    /// type, wherever it lives.
    app_reach: []const u8 = "",
    /// The operation whose run made this call, empty for a call an adapter made: a policy
    /// tells a plugin operation's own writes from the same caller writing directly.
    within: []const u8 = "",
    /// The plugin whose code is running: its operation or one of its hooks, compiled in or
    /// installed. Empty for the core's own code; a core operation a plugin calls keeps it.
    plugin: []const u8 = "",
    /// Whether that plugin's own code makes the calls now (its operation, hook or job), not a
    /// core operation it called: a compiled-in plugin's calls are held to its grants then.
    plugin_code: bool = false,
    /// Whether the operation running now was called by that code: what it asks about its
    /// caller (may it publish) answers for the plugin.
    plugin_called: bool = false,
    /// The queued job running (`<plugin>.<name>`): the author of what it changes. Empty
    /// outside a job.
    job: []const u8 = "",
    /// The language the admin speaks to the caller, for a page a plugin draws: its
    /// catalogue for the render and its script for the browser. Empty outside the admin.
    language: Language = .{},
    db: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    auth: *AuthState,
    parent: ?OperationId = null,
    now_ms: i64,
    next_operation_id: OperationId = 1,
    notify: ?Notify = null,
    /// Events kept outside the write that raised them (a sign-in refused, an error): queued
    /// for `on` hooks once the top-level call ended, kept or rolled back (`SDK.flush_kept`).
    kept_events: ?*std.ArrayList(Emitted) = null,
    /// The top-level call's trail, for the activity and error logs (`sdk/trail.zig`).
    trail: ?*@import("trail.zig").Trail = null,
    /// Where on the trail the operation running now started (`Trail.mark`): what its
    /// `after` hooks place the units it changed at.
    trail_start: u32 = 0,
    /// What plugins log (`ctx.log`) during the top-level call or queued run; null outside
    /// one, where a line goes to the server's output.
    lines: ?*@import("trail.zig").Lines = null,
    /// The installed plugins installed in the project: their operations and hooks.
    sandboxed_plugins: ?*const @import("sandboxed_plugins.zig").SandboxedPlugins = null,
    /// Every compiled-in plugin's `State` (`publr.plugin_states.of`), where a server made them.
    plugin_states: ?*anyopaque = null,
    /// How deep calls nest through installed plugins, bounded by `plugins.depth_max`.
    plugin_depth: u32 = 0,
    /// Set while a modifier or a `before` hook on a sign-in runs: it may read what it is
    /// granted, never write.
    reads_only: bool = false,
    /// Where the media library keeps its files, where a server made it.
    files: ?@import("../lib/files.zig").Files = null,
    /// The project's apps, where a server holds them.
    apps: ?AppsFolder = null,
    /// Where installed translations disagree, where a server worked it out.
    translations: ?Translations = null,
    /// Building plugins from their sources, where a server carries the compiler.
    builder: ?PluginBuilder = null,
    /// Running a conversation's turn beside the server, where one runs.
    agents: ?AgentStarter = null,
    /// The pages watching conversations, where `serve` holds them.
    live: ?Live = null,
    /// A removal kept its copy in the trash: the final removals it runs on its way (a media
    /// file's record purged) are part of it, so a device runs them too.
    kept: bool = false,
    /// A model's words as they come, where an agent runs a turn.
    progress: ?Progress = null,
    /// Responses a plugin reads piece by piece (`http.stream`), where a process holds them
    /// across its calls: an agent's. `operations/http_stream.zig`'s `Streams`.
    streams: ?*anyopaque = null,
    /// Updating Publr, where `serve` runs it.
    updater: ?Updater = null,
    /// The device sending the call said `--production`: it means the site itself, not a copy
    /// of it. The core reads it nowhere; a hosting service's plugin may.
    production: bool = false,
    /// Where plugins' outside calls may go: production (the default) refuses local and
    /// private addresses and the server's own hosts; a laptop's `serve` over plain http
    /// lets a listed `localhost` in.
    outside: @import("../model/outside.zig").Rule = .{},
    /// The first refusal of an `after` hook on an event emitted in this write: the write
    /// fails with it before it commits.
    event_refusal: ?@import("operation.zig").Error = null,
    /// A write so far changed what visitors see (a document put live or taken off, set by
    /// the move itself): what a `drafts` device may not do.
    publishes: bool = false,
    /// The request's scratch (`scratch.zig`), set aside the first time a loop asks for it
    /// and shared by every call nested in the request, and by copies of this context.
    scratch_set_aside: ?*Scratch = null,
    /// The definitions this request has read (`definition_cache.zig`), where a server keeps
    /// them; shared by every context made for the request.
    definitions: ?*DefinitionCache = null,

    /// `message` in `locale` for people outside the admin (an email, a plugin's own page):
    /// the source text where no plugin translates it. Outside a server, which builds the
    /// languages, the source text as written.
    pub fn say(
        ctx: *const Ctx,
        locale: []const u8,
        message: Message,
    ) std.mem.Allocator.Error![]const u8 {
        std.debug.assert(message.id.len > 0);
        std.debug.assert(message.plural.len == 0 or message.count != null);

        const view = ctx.translations orelse return filled(ctx.arena, message);

        return view.say(view.context, ctx.arena, locale, message);
    }

    pub fn init(
        database: *db.Db,
        io: std.Io,
        arena: std.mem.Allocator,
        auth: *AuthState,
        caller: Caller,
        options: Options,
    ) Ctx {
        std.debug.assert(options.now_ms >= 0);

        return .{
            .caller = caller,
            .db = database,
            .io = io,
            .arena = arena,
            .auth = auth,
            .now_ms = options.now_ms,
        };
    }

    /// Working memory for a loop's items: `mark` before an item, `rewind` after it.
    pub fn scratch(ctx: *Ctx) error{OutOfMemory}!*Scratch {
        if (ctx.scratch_set_aside) |set_aside| {
            return set_aside;
        }

        const set_aside = try ctx.arena.create(Scratch);

        set_aside.* = .{
            .fixed = .init(try ctx.arena.alloc(u8, @import("scratch.zig").bytes_default)),
        };
        ctx.scratch_set_aside = set_aside;

        std.debug.assert(ctx.scratch_set_aside != null);

        return set_aside;
    }

    /// A write ran: the definitions are read again.
    pub fn forget_definitions(ctx: *Ctx) void {
        if (ctx.definitions) |cache| {
            cache.forget();
        }
    }

    /// Ends the operation with a failure its plugin declares: `return ctx.fail(unverified);`.
    /// The write is rolled back like any other error's.
    pub fn fail(ctx: *Ctx, failure: @import("operation.zig").Failure) error{Failed} {
        std.debug.assert(failure.name.len > 0);
        std.debug.assert(failure.status >= 400 and failure.status <= 599);

        ctx.failure = failure;

        return error.Failed;
    }

    /// Refuses the input with every problem found at once: `error.Invalid`, answered as
    /// `{ "error": "Invalid", "problems": [ { "field", "message" } ] }`.
    pub fn refuse(
        ctx: *Ctx,
        problems: []const @import("operation.zig").Problem,
    ) error{Invalid} {
        std.debug.assert(problems.len > 0);
        std.debug.assert(problems.len <= @import("operation.zig").problems_max);

        ctx.problems = problems;

        return error.Invalid;
    }

    /// Emits one of core's events (`role.created`, made with `publr.event.define`): `after`
    /// hooks on it run now, inside the write; `on` hooks hear it from the queue once it
    /// commits.
    pub fn emit(ctx: *Ctx, comptime Event: type, payload: Event.Payload) void {
        comptime std.debug.assert(Event.full_name.len > 0);
        std.debug.assert(ctx.parent != null);

        const text = std.json.Stringify.valueAlloc(ctx.arena, payload, .{}) catch {
            ctx.event_refusal = ctx.event_refusal orelse error.OutOfMemory;
            return;
        };

        ctx.emit_json(Event.full_name, text, true);
    }

    /// An event by name with its payload as JSON: kept on the trail and queued for the `on`
    /// hooks, its `after` hooks run first when `run_after` (a plugin's typed `ctx.emit`, an
    /// installed plugin's). Core runs them itself, by its own rules, for its events whose
    /// hooks it runs (a sign-in spares an administrator; a move's hooks hear the transition).
    pub fn emit_json(ctx: *Ctx, name: []const u8, payload: []const u8, run_after: bool) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.parent != null);

        const hand = ctx.notify orelse return;
        hand(ctx, .{
            .operation_id = ctx.parent.?,
            .name = name,
            .subject = payload,
        }, run_after);
    }

    /// Keeps one of core's events outside the write running now: a refusal people hear of
    /// (`publr.auth.SignInFailed`) or an error (`publr.errors.Failed`). Only `on` hooks hear
    /// it, once the top-level call ended; the write rolling back does not drop it.
    pub fn keep(ctx: *Ctx, comptime Event: type, payload: Event.Payload) void {
        comptime std.debug.assert(Event.full_name.len > 0);
        std.debug.assert(ctx.now_ms >= 0);

        const text = std.json.Stringify.valueAlloc(ctx.arena, payload, .{}) catch {
            std.log.warn("events: {s} not kept: out of memory", .{Event.full_name});
            return;
        };
        const list = ctx.kept_events orelse made: {
            const made = ctx.arena.create(std.ArrayList(Emitted)) catch {
                std.log.warn("events: {s} not kept: out of memory", .{Event.full_name});
                return;
            };

            made.* = .empty;
            ctx.kept_events = made;
            break :made made;
        };
        const operation_id = ctx.parent orelse ctx.allocate_operation_id();

        list.append(ctx.arena, .{
            .operation_id = operation_id,
            .name = Event.full_name,
            .subject = text,
        }) catch {
            std.log.warn("events: {s} not kept: out of memory", .{Event.full_name});
        };
    }

    pub fn allocate_operation_id(ctx: *Ctx) OperationId {
        const id = ctx.next_operation_id;
        std.debug.assert(id != 0);

        ctx.next_operation_id += 1;
        std.debug.assert(ctx.next_operation_id > id);

        return id;
    }

    pub const Options = struct {
        now_ms: i64 = 0,
    };
};

pub fn wall_clock_ms(io: std.Io) i64 {
    const now = std.Io.Clock.real.now(io);
    const ms: i64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));

    std.debug.assert(ms >= 0);
    std.debug.assert(ms < std.math.maxInt(i64) / 2);

    return ms;
}

test "operation ids are unique and increasing within a ctx" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var auth_state: AuthState = undefined;
    const params = @import("../lib/auth.zig").password.params_test;
    try auth_state.init(std.testing.allocator, std.testing.io, .{
        .params = params,
    });
    defer auth_state.deinit();

    var buffer: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);
    var ctx = Ctx.init(
        &fixture.connection,
        std.testing.io,
        fixed.allocator(),
        &auth_state,
        .system,
        .{},
    );

    const first = ctx.allocate_operation_id();
    const second = ctx.allocate_operation_id();

    try std.testing.expect(second > first);
    try std.testing.expectEqual(@as(?OperationId, null), ctx.parent);
    try std.testing.expect(wall_clock_ms(std.testing.io) > 1_700_000_000_000);
}
