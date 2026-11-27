const std = @import("std");
const db = @import("../lib/db.zig");
const Caller = @import("caller.zig").Caller;
const AuthState = @import("../lib/auth.zig").State;
const Emitted = @import("hooks.zig").Event.Emitted;
const Scratch = @import("scratch.zig").Scratch;
const DefinitionCache = @import("definition_cache.zig").DefinitionCache;

pub const OperationId = u64;

/// Where an emitted event goes: `after` hooks by name when `after` (a plugin's event, core's
/// typed ones), then the queue for the `on` hooks.
pub const Notify = *const fn (ctx: *Ctx, emitted: Emitted, after: bool) void;

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

/// What a page for the built site read while it was drawn (`adapters/apps/context.zig`'s
/// `Deps`): every key a read on the way names, whoever's code made it, so a write to any of
/// them rebuilds the page.
pub const Reads = struct {
    context: *anyopaque,
    read: *const fn (context: *anyopaque, key: []const u8) void,
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

pub const UpdateBackup = @import("../publr/model/release.zig").UpdateBackup;

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
    /// Every language the catalogues hold, compiled-in plugins' and installed ones'.
    spoken: *const fn (
        context: *const anyopaque,
        arena: std.mem.Allocator,
    ) std.mem.Allocator.Error![]const Spoken,
};

/// A language the admin can speak: `pl`, `Polski`.
pub const Spoken = struct {
    locale: []const u8,
    label: []const u8,
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

    pub const Value = @import("../publr/ctx/said.zig").Said;
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

/// What a view's `ctx` carries on the server: who is looking, and the page.
pub const View = struct {
    person: Person = .{},
    page: Page = .{},
    /// A field kind's editor: the value it edits, its problems and the field's options.
    editor: ?Editor = null,

    pub const Editor = struct {
        /// Null on a new record.
        value: std.json.Value = .null,
        problems: []const []const u8 = &.{},
        options: Options = .{},
    };

    /// The field's options an editor is told.
    pub const Options = struct {
        placeholder: []const u8 = "",
    };

    pub const Person = struct {
        name: []const u8 = "",
        email: []const u8 = "",
    };

    /// The page's path among the plugin's pages (empty for a panel), and its query string.
    pub const Page = struct {
        path: []const u8 = "",
        query: []const u8 = "",
    };
};

pub const Ctx = struct {
    dependency_failure: bool = false,

    /// Why the last operation ended with `error.Failed`: set by `fail`, read by adapters.
    failure: ?@import("operation.zig").Failure = null,
    /// What was wrong with the input when it ended with `error.Invalid`, every field at
    /// once: set by `refuse`, answered as `problems`.
    problems: []const @import("operation.zig").Problem = &.{},
    caller: Caller,
    /// The account the local operator stands for (`--as-admin`, the oldest administrator):
    /// what they write is theirs. Empty otherwise.
    operator: []const u8 = "",
    /// Reads made to render a page for a visitor: live records only and never a write,
    /// whoever the caller is, so a signed-in visitor never sees a draft on the site.
    delivery: bool = false,
    /// Reads made to draw a preview of the site: never a write, and every record read is its
    /// edit copy (pending changes, else the record as saved), drafts included, never the
    /// trash, so the site reads as it will once everything edited is published.
    preview: bool = false,
    /// The code a page for a visitor or a preview is at in the dimension with pages of its
    /// own (its language), from the address; empty: the main one.
    address_code: []const u8 = "",
    /// The combination a page for a visitor or a preview reads documents in, highest
    /// priority first: the addressed dimension's code from the address, the others as the
    /// request chose them. Empty: the main values.
    dimensions: []const @import("../model/dimension.zig").Pair = &.{},
    /// The app a request came through (`app.zon`'s `.name`), empty for the admin, the CLI and
    /// the API: a document created on the way belongs to it.
    app: []const u8 = "",
    /// The address of the app the request came through, its origin and mount
    /// (`https://example.com/shop`): where a link sent to a visitor leads. Empty when the
    /// request came through no app.
    app_address: []const u8 = "",
    /// The visitor's stable id (the `publr_visitor` cookie) when the call came from an app's
    /// page, island or `/_actions`; empty otherwise. Beside the user once they sign in.
    visitor: []const u8 = "",
    /// The address the request came from (`limits.address_of`); empty for a context no
    /// request made, which no rate limit counts.
    address: []const u8 = "",
    /// The call came to REST (`/api/<plugin>.<verb>`): a device token there calls from the
    /// API, not the command line.
    over_api: bool = false,
    /// The page that sent the request when it is another site's (the `Referer` header);
    /// empty for our own pages and a request that names none. Tells, never grants.
    referer: []const u8 = "",
    /// The `Cookie` header the visitor's call came with, from the site's own pages; read
    /// only by name, by a plugin declaring it (`request.read`).
    cookies: []const u8 = "",
    /// A plugin's page or panel being drawn in the plugin frame: who is looking and the
    /// page, what its view's `ctx` carries. Empty outside one.
    view: View = .{},
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
    /// The compiled-in plugin whose code called the operation running now; empty when none.
    called_by: []const u8 = "",
    /// The plugin whose code called the plugin operation running now, directly: the ledger
    /// accounts it handed over by calling, which that operation may move for it. Empty in
    /// hooks and when no plugin called.
    handed_by: []const u8 = "",
    /// Whether that plugin's operation running now is `.destructive`: only then may the core
    /// operations it calls destroy.
    destructive: bool = false,
    /// The queued job running (`<plugin>.<name>`): the author of what it changes. Empty
    /// outside a job.
    job: []const u8 = "",
    /// The queued run's write (`sdk/job_write.zig`), while a job or an `on` hook runs.
    job_write: ?*@import("job_write.zig").JobWrite = null,
    /// The parsed query `publr.query.prepare` keeps, handed to the `record.query` call it
    /// makes with the same text, which then runs it without parsing again.
    prepared: ?*const @import("../lib/groq.zig").Prepared = null,
    /// The language the admin speaks to the caller, for a page a plugin draws: its
    /// catalogue for the render and its script for the browser. In queued work, its locale
    /// alone: the one the work was queued with, else the site's. Empty elsewhere.
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
    /// The memory that lasts the whole call, while `arena` is a nested installed call's
    /// working memory, given back once it answered (`call_json.zig`): what must outlive the
    /// nested call (kept events) goes here. Null when `arena` is that memory.
    lasting: ?std.mem.Allocator = null,
    /// The memory the top-level call running now began in, when that lasts the call: where
    /// what outlives a piece of its work is kept, however deep in loops and nested calls
    /// the work is (`kept_memory`, `keep`). Null outside a call, and for a call that itself
    /// began inside a scratch.
    call_memory: ?std.mem.Allocator = null,
    /// The site's currencies as this call first read them (`site_currencies.zig`): a page
    /// that writes many amounts asks the plugin naming them once.
    site_currencies: ?[]const @import("../model/money.zig").Entry = null,
    /// Where media addresses start as this call first read it (`media_base.zig`): a page
    /// that shows many files asks the plugins changing it once.
    media_base: ?[]const u8 = null,
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
    /// Where a page drawn for the built site writes down what it reads; null outside one.
    /// Every read core makes on its way (a record, a listing, a query, an internal record)
    /// names its key there, plugins' reads included.
    reads: ?Reads = null,
    /// How deep computed fields being worked out nest (a line's price reading its cart's own
    /// computed field): past `operations/internal/computed.zig`'s limit a read takes the
    /// value as stored, so values that read each other never go round for ever.
    computing_depth: u32 = 0,
    /// Set while a modifier or a `before` hook on a sign-in runs: it may read what it is
    /// granted, never write.
    reads_only: bool = false,
    /// The values of an apply a plugin's code hands `mod.apply` held laid out
    /// (`server/sandboxed_plugins/applied.zig`), and where it finds them afterwards: they
    /// never become the operation's JSON. Null for an apply from the outer edge.
    applying: ?*[]const u8 = null,
    /// Where the media library keeps its files, where a server made it.
    files: ?@import("../lib/files.zig").Files = null,
    /// The project's apps, where a server holds them.
    apps: ?AppsFolder = null,
    /// Where installed translations disagree, where a server worked it out.
    translations: ?Translations = null,
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
    /// This process is a copy of the site, an environment or a branch, not the site itself:
    /// said by the plugin that keeps copies. A `write` device publishes freely here.
    on_copy: bool = false,
    /// This process may move the site's clock (`operations/clock.zig`): a test site, never
    /// production or a copy.
    test_clock: bool = false,
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
    /// Nested installed calls' working memory (`call_json.zig`), apart from the loops'
    /// scratch: a loop inside a call pages through its own.
    calls_set_aside: ?*Scratch = null,
    /// Compiled-in plugins' working memory (`plugin_memory.zig`), where the process set it
    /// aside: each piece of a plugin's work holds pages of it and gives them back as it ends.
    plugins_set_aside: ?*@import("plugin_memory.zig").Memory = null,
    /// The walks a compiled-in plugin has open (`publr.Rows`), each page and turn a piece of
    /// its work that stays here until it ends.
    walks: @import("plugin/walks/native.zig").Stack = .{},
    /// The definitions this request has read (`definition_cache.zig`), where a server keeps
    /// them; shared by every context made for the request.
    definitions: ?*DefinitionCache = null,
    /// The field kinds while an installed plugin's own types are made, before it loads: the
    /// project's and its own. Null reads the project's (`registry.kinds`).
    kinds: ?[]const @import("../model/kinds.zig").Kind = null,

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

    /// A read names what it read (`record:<id>`, `type:<handle>`, `internal:<plugin>/<kind>`)
    /// when a page for the built site is being drawn: the page depends on it.
    pub fn depends_on(ctx: *const Ctx, key: []const u8) void {
        std.debug.assert(key.len > 0);

        const reads = ctx.reads orelse return;

        reads.read(reads.context, key);
    }

    /// The language queued work this call queues speaks: the page's (`address_code`), else
    /// the person's (`language`), carried in the job's row.
    pub fn language_queued(ctx: *const Ctx) []const u8 {
        std.debug.assert(ctx.address_code.len <= 64);
        std.debug.assert(ctx.language.locale.len <= 64);

        return if (ctx.address_code.len > 0) ctx.address_code else ctx.language.locale;
    }

    /// The language a plugin's `ctx.t` answers this call in: the person's (`language`), else
    /// the page's (`address_code`), else, for a visitor of an app, the site's: a shop whose
    /// site speaks Polish tells its buyers in Polish. Empty for English.
    pub fn speaks(ctx: *Ctx) []const u8 {
        std.debug.assert(ctx.language.locale.len <= 64);
        std.debug.assert(ctx.address_code.len <= 64);

        if (ctx.language.locale.len > 0) {
            return ctx.language.locale;
        }

        if (ctx.address_code.len > 0 or ctx.app.len == 0) {
            return ctx.address_code;
        }

        return @import("../operations/user/language.zig").site_speaks(ctx) catch |err| {
            std.log.warn("ctx.t: the site's language not read: {t}", .{err});
            return "";
        };
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

        const memory = ctx.lasting orelse ctx.arena;
        const set_aside = try memory.create(Scratch);

        set_aside.* = .{
            .fixed = .init(try memory.alloc(u8, @import("scratch.zig").bytes_default)),
        };
        ctx.scratch_set_aside = set_aside;

        std.debug.assert(ctx.scratch_set_aside != null);

        return set_aside;
    }

    /// Working memory for nested installed calls: `mark` before one, `rewind` once its
    /// answer is copied out. Set aside from the arena the first time.
    pub fn call_scratch(ctx: *Ctx) error{OutOfMemory}!*Scratch {
        if (ctx.calls_set_aside) |set_aside| {
            return set_aside;
        }

        const memory = ctx.lasting orelse ctx.arena;
        const set_aside = try memory.create(Scratch);

        set_aside.* = .{
            .fixed = .init(try memory.alloc(u8, @import("scratch.zig").call_bytes)),
        };
        ctx.calls_set_aside = set_aside;

        std.debug.assert(ctx.calls_set_aside != null);

        return set_aside;
    }

    /// Memory that lasts the top-level call, for what a piece of work keeps past itself
    /// (the site's currencies as first read). Null when the call works in a scratch given
    /// back item by item and names nowhere that lasts: what would be kept is then made
    /// again when it is needed, never left where the next item overwrites it.
    pub fn kept_memory(ctx: *const Ctx) ?std.mem.Allocator {
        std.debug.assert(ctx.now_ms >= 0);

        if (ctx.call_memory) |memory| {
            return memory;
        }

        if (ctx.lasting) |memory| {
            if (!ctx.given_back(memory)) {
                return memory;
            }
        }

        return if (ctx.given_back(ctx.arena)) null else ctx.arena;
    }

    /// Whether `memory` is one of the request's scratches or a piece of a compiled-in
    /// plugin's work: given back before the call ends.
    fn given_back(ctx: *const Ctx, memory: std.mem.Allocator) bool {
        std.debug.assert(ctx.now_ms >= 0);

        if (@import("plugin_memory.zig").is_work(memory)) {
            return true;
        }

        if (ctx.scratch_set_aside) |set_aside| {
            if (set_aside.holds(memory)) {
                return true;
            }
        }

        const working = ctx.calls_set_aside orelse return false;

        return working.holds(memory);
    }

    /// A write ran: the definitions are read again.
    pub fn forget_definitions(ctx: *Ctx) void {
        if (ctx.definitions) |cache| {
            cache.forget();
        }
    }

    /// Ends the operation with a failure its plugin declares: `return ctx.fail(unverified);`.
    /// The write is rolled back like any other error's.
    /// Whose a write is: the account calling, or the one the local operator stands for.
    pub fn author(ctx: *const Ctx) ?[]const u8 {
        if (ctx.caller.user_id()) |id| {
            return id;
        }

        return if (ctx.operator.len > 0) ctx.operator else null;
    }

    /// Whether the device making this call must leave what visitors see as it is: a device
    /// that may not publish here. False for anyone else.
    pub fn drafts_only(ctx: *const Ctx) bool {
        std.debug.assert(ctx.now_ms >= 0 or ctx.caller == .token);

        const scope = ctx.caller.scope() orelse return false;

        return switch (scope) {
            .publish => false,
            .write => !ctx.on_copy,
            .read, .production => true,
        };
    }

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

        // Never a loop's or a nested call's scratch, given back before the call ends, when
        // the call began anywhere that lasts it. A call that began inside a scratch flushes
        // what it kept as it ends, before whoever owns the scratch gives it back.
        const memory = ctx.kept_memory() orelse ctx.lasting orelse ctx.arena;
        const text = std.json.Stringify.valueAlloc(memory, payload, .{}) catch {
            std.log.warn("events: {s} not kept: out of memory", .{Event.full_name});
            return;
        };
        const list = ctx.kept_events orelse made: {
            const made = memory.create(std.ArrayList(Emitted)) catch {
                std.log.warn("events: {s} not kept: out of memory", .{Event.full_name});
                return;
            };

            made.* = .empty;
            ctx.kept_events = made;
            break :made made;
        };
        const operation_id = ctx.parent orelse ctx.allocate_operation_id();

        list.append(memory, .{
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

/// Unix milliseconds now, defined in `publr/extend/clock.zig` (`publr.Host.wall_clock_ms`).
pub const wall_clock_ms = @import("../publr/extend/clock.zig").wall_clock_ms;

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

test "who must leave what visitors see alone" {
    const token = struct {
        fn of(scope: @import("../model/device.zig").Scope, on_copy: bool) bool {
            std.debug.assert(@backingInt(scope) < 4);

            var ctx: Ctx = undefined;

            ctx.caller = .{
                .token = .{
                    .id = "d",
                    .user_id = "u",
                    .scope = scope,
                },
            };
            ctx.on_copy = on_copy;

            return ctx.drafts_only();
        }
    }.of;

    try std.testing.expect(token(.production, false));
    try std.testing.expect(token(.production, true));
    try std.testing.expect(token(.write, false));
    try std.testing.expect(!token(.write, true));
    try std.testing.expect(!token(.publish, false));
}

test "what is kept for the call is never kept in a scratch given back before it ends" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var loop_buffer: [64]u8 = undefined;
    var loop: Scratch = .{
        .fixed = .init(&loop_buffer),
    };
    var calls_buffer: [64]u8 = undefined;
    var calls: Scratch = .{
        .fixed = .init(&calls_buffer),
    };
    var connection: db.Db = undefined;
    var auth: AuthState = undefined;
    var ctx = Ctx.init(&connection, std.testing.io, arena, &auth, .system, .{});

    ctx.scratch_set_aside = &loop;
    ctx.calls_set_aside = &calls;

    // In the request's own memory: kept there.
    try std.testing.expect(ctx.kept_memory().?.ptr == arena.ptr);

    // An item of a loop works in the scratch, with nowhere that lasts named: nothing kept.
    ctx.arena = loop.allocator();
    try std.testing.expect(ctx.kept_memory() == null);

    // A plugin's work inside that item names the item's scratch as what lasts it: still none.
    ctx.lasting = loop.allocator();
    ctx.arena = calls.allocator();
    try std.testing.expect(ctx.kept_memory() == null);

    // An installed operation called from the request's memory: kept there.
    ctx.lasting = arena;
    try std.testing.expect(ctx.kept_memory().?.ptr == arena.ptr);

    // A call that began in the request's memory keeps there from any depth of its work.
    ctx.call_memory = arena;
    ctx.lasting = loop.allocator();
    ctx.arena = calls.allocator();
    try std.testing.expect(ctx.kept_memory().?.ptr == arena.ptr);
}

test "an event kept inside a loop's item is read whole after the item's scratch is given back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var loop_buffer: [1024]u8 = undefined;
    var loop: Scratch = .{
        .fixed = .init(&loop_buffer),
    };
    var connection: db.Db = undefined;
    var auth: AuthState = undefined;
    var ctx = Ctx.init(&connection, std.testing.io, arena, &auth, .system, .{});
    const Happened = struct {
        pub const full_name = "probe.happened";
        pub const Payload = struct {
            word: []const u8,
        };
    };

    ctx.scratch_set_aside = &loop;
    ctx.call_memory = ctx.kept_memory();

    // Each item of the loop works in the scratch and keeps an event; the scratch is given
    // back (and overwritten by the next item) before the call ends.
    for ([_][]const u8{ "first", "second" }) |word| {
        const at = loop.mark();

        ctx.arena = loop.allocator();
        ctx.keep(Happened, .{
            .word = word,
        });
        _ = try ctx.arena.alloc(u8, 512);
        loop.rewind(at);
        @memset(&loop_buffer, 0xaa);
    }

    ctx.arena = arena;

    const kept = ctx.kept_events.?.items;

    try std.testing.expectEqual(@as(usize, 2), kept.len);
    try std.testing.expectEqualStrings("{\"word\":\"first\"}", kept[0].subject);
    try std.testing.expectEqualStrings("{\"word\":\"second\"}", kept[1].subject);
}
