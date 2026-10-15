const std = @import("std");
const db = @import("../lib/db.zig");
const Caller = @import("caller.zig").Caller;
const AuthState = @import("../lib/auth.zig").State;
const Notice = @import("middleware.zig").Event.Notice;
const Scratch = @import("scratch.zig").Scratch;
const DefinitionCache = @import("definition_cache.zig").DefinitionCache;

pub const OperationId = u64;
pub const request_id_len_max: u32 = 64;

pub const Notify = *const fn (ctx: *Ctx, notice: Notice) void;

/// The folder the running server reads the project's apps from, and a way to read them
/// again: what the `apps` operations change.
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
    /// The releases newer than this one, from where Publr publishes them; null when they
    /// could not be reached.
    releases: *const fn (
        context: *anyopaque,
        arena: std.mem.Allocator,
    ) ?[]const @import("../model/release.zig").Release,
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

pub const AppsFolder = struct {
    context: *anyopaque,
    dir: []const u8,
    /// The apps read again and swapped in: null when they load, else why they do not.
    reload: *const fn (context: *anyopaque) ?[]const u8,
};

pub const Ctx = struct {
    dependencies: ?*@import("dependencies.zig").Collector = null,
    dependency_failure: bool = false,

    /// Why the last operation ended with `error.Failed`: set by `fail`, read by adapters.
    failure: ?@import("operation.zig").Failure = null,
    publish_policy: ?*const fn (*Ctx, OperationPolicy) anyerror!void = null,
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
    /// page, island or `_api`; empty otherwise. Beside the user once they sign in.
    visitor: []const u8 = "",
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
    /// The language the admin speaks to the caller, for a page a plugin draws: its
    /// catalogue for the render and its script for the browser. Empty outside the admin.
    language: Language = .{},
    db: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    auth: *AuthState,
    request_id: []const u8 = "",
    parent: ?OperationId = null,
    now_ms: i64,
    next_operation_id: OperationId = 1,
    notify: ?Notify = null,
    /// The top-level call's trail, for the activity and error logs (`sdk/trail.zig`).
    trail: ?*@import("trail.zig").Trail = null,
    /// The installed plugins installed in the project: their operations and hooks.
    sandboxed_plugins: ?*const @import("sandboxed_plugins.zig").SandboxedPlugins = null,
    /// Every compiled-in plugin's `State` (`publr.plugin_states.of`), where a server made them.
    plugin_states: ?*anyopaque = null,
    /// How deep calls nest through installed plugins, bounded by `plugins.depth_max`.
    plugin_depth: u32 = 0,
    /// Set while a display hook runs: it may read what it is granted, never write.
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
    /// A write so far changed what visitors see (a `published` or `unpublished` notice):
    /// what a `drafts` device may not do.
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

    pub fn init(options: Options) Ctx {
        std.debug.assert(options.request_id.len <= request_id_len_max);
        std.debug.assert(options.now_ms >= 0);

        return .{
            .caller = options.caller,
            .db = options.db,
            .io = options.io,
            .arena = options.arena,
            .auth = options.auth,
            .request_id = options.request_id,
            .now_ms = options.now_ms,
        };
    }

    pub const OperationPolicy = struct {
        revision: u64,
        no_store: bool,
        revalidate: bool,
        expires: ?i64,
        tags: []const []const u8,
    };

    /// Called by name from the PJSX runtime, hence the name.
    pub fn publrPolicy(ctx: *Ctx, policy: anytype) !void {
        std.debug.assert(policy.expires == null or policy.expires.? >= 0);

        const restricted = policy.no_store or policy.revalidate or
            policy.expires != null or policy.tags.len > 0;

        if (ctx.publish_policy) |publish| {
            return publish(ctx, .{
                .revision = policy.revision,
                .no_store = policy.no_store,
                .revalidate = policy.revalidate,
                .expires = policy.expires,
                .tags = policy.tags,
            });
        }

        if (restricted) {
            return error.PolicyHeadersRequired;
        }
    }

    pub fn collecting(ctx: *Ctx, collector: *@import("dependencies.zig").Collector) Ctx {
        std.debug.assert(collector != ctx.dependencies);
        std.debug.assert(collector.keys.items.len == 0);

        var owned = ctx.*;

        collector.parent = ctx.dependencies;
        owned.dependencies = collector;

        return owned;
    }

    pub fn depend(ctx: *Ctx, prefix: []const u8, id: []const u8) void {
        std.debug.assert(prefix.len + id.len > 0);

        if (ctx.dependencies) |collector| {
            collector.depend(prefix, id);
        }
    }

    /// Ends the operation with a failure its plugin declares: `return ctx.fail(unverified);`.
    /// The write is rolled back like any other error's.
    /// Working memory for a loop's items: `mark` before an item, `rewind` after it.
    pub fn scratch(ctx: *Ctx) error{OutOfMemory}!*Scratch {
        if (ctx.scratch_set_aside) |set_aside| {
            return set_aside;
        }

        const set_aside = try ctx.arena.create(Scratch);

        set_aside.* = try .init(ctx.arena, @import("scratch.zig").bytes_default);
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

    pub fn fail(ctx: *Ctx, failure: @import("operation.zig").Failure) error{Failed} {
        std.debug.assert(failure.name.len > 0);
        std.debug.assert(failure.status >= 400 and failure.status <= 599);

        ctx.failure = failure;

        return error.Failed;
    }

    pub fn notice(ctx: *Ctx, name: []const u8, subject: []const u8) void {
        std.debug.assert(name.len > 0);
        std.debug.assert(ctx.parent != null);

        const emit = ctx.notify orelse return;
        emit(ctx, .{
            .operation_id = ctx.parent.?,
            .name = name,
            .subject = subject,
        });
    }

    pub fn allocate_operation_id(ctx: *Ctx) OperationId {
        const id = ctx.next_operation_id;
        std.debug.assert(id != 0);

        ctx.next_operation_id += 1;
        std.debug.assert(ctx.next_operation_id > id);

        return id;
    }

    pub const Options = struct {
        caller: Caller,
        db: *db.Db,
        io: std.Io,
        arena: std.mem.Allocator,
        auth: *AuthState,
        request_id: []const u8 = "",
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
    var ctx = Ctx.init(.{
        .caller = .system,
        .db = &fixture.connection,
        .io = std.testing.io,
        .arena = fixed.allocator(),
        .auth = &auth_state,
    });

    const first = ctx.allocate_operation_id();
    const second = ctx.allocate_operation_id();

    try std.testing.expect(second > first);
    try std.testing.expectEqual(@as(?OperationId, null), ctx.parent);
    try std.testing.expect(wall_clock_ms(std.testing.io) > 1_700_000_000_000);
}
