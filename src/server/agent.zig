//! `publr agent --conversation <id>`: one conversation's turn, in a process of its own
//! beside the server that started it. It takes the device the turn runs as (`ai begin`),
//! runs the model's loop with the `run` and `guide` tools, reports each step (`ai step`),
//! and ends the turn (`ai finish`), which revokes the device. Started by the server, never
//! by hand.

const std = @import("std");
const ai = @import("../lib/ai.zig");
const model_ai = @import("../model/ai.zig");
const environment = @import("../lib/environment.zig");
const Camera = @import("agent/screenshot.zig").Camera;
const history = @import("agent/history.zig");
const Drafter = @import("agent/drafter.zig").Drafter;
const watchdog_module = @import("agent/watchdog.zig");
const site_page_module = @import("agent/site_page.zig");
const operator = @import("operator.zig");
const channel_module = @import("agent/channel.zig");
const tools_module = @import("agent/tools.zig");
const browser_module = @import("agent/browser.zig");
const Activity = @import("agent/activity.zig").Activity;
const effort_module = @import("agent/effort.zig");
const Stopper = @import("agent/stopper.zig").Stopper;
const downloads_module = @import("agent/downloads.zig");
const Crawl = @import("agent/crawl.zig").Crawl;
const turn = @import("../operations/ai/turn.zig");
const providers = @import("../operations/ai/providers.zig");
const server = @import("../server.zig");
const PluginProvider = @import("agent/plugin_provider.zig").PluginProvider;
const presented = @import("../model/ai_presented.zig");

const Channel = channel_module.Channel;

const Begun = struct {
    token: []const u8,
    prompt: []const u8,
    pictures: []const []const u8 = &.{},
    history: []const turn.Said = &.{},
    scope: []const u8,
    provider: []const u8,
    model: []const u8,
};

const Recorded = struct {
    position: u32,
    go_on: bool,
};

/// Model calls in one turn, at most.
/// Model replies in one turn, at most: as many as the conversation keeps steps. A turn is
/// not cut short by a count; a runaway is caught by `Runaway` instead.
pub const steps_max: u32 = model_ai.steps_max;
/// The same call failing the same way this many times in a row ends the turn.
const repeats_max: u32 = 3;
const script_bytes_max: u32 = 1 << 20;

pub fn run(init: std.process.Init, db_path: []const u8, args: []const []const u8) !u8 {
    std.debug.assert(db_path.len > 0);
    std.debug.assert(args.len <= 64);

    // A turn's own memory, from pages: it may run for minutes and call out many times.
    var turn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer turn_arena.deinit();

    const arena = turn_arena.allocator();
    const worker = args.len == 3 and std.mem.eql(u8, args[2], "--worker");

    if (args.len < 2 or !std.mem.eql(u8, args[0], "--conversation") or args[1].len == 0) {
        std.debug.print("usage: publr agent --conversation <id>\n", .{});
        return 2;
    }

    if (!worker) {
        return supervise(init, arena, db_path, args[1]);
    }

    const session = try operator.find(init.io, arena, db_path) orelse {
        std.debug.print("publr agent: no server runs for {s}\n", .{db_path});
        return 1;
    };
    var channel = Channel.of(init.io, arena, session);
    var watchdog: watchdog_module.Watchdog = .{
        .io = init.io,
    };

    try watchdog.start();

    var reporter: Reporter = .{
        .channel = &channel,
        .id = args[1],
        .watchdog = &watchdog,
    };
    const begin = [_][]const u8{ "--as-admin", "ai", "begin", "--id", reporter.id };
    const begun = try channel.operate(Begun, &begin);

    channel.token = begun.token;

    const outcome = take_turn(init, arena, db_path, &reporter, begun) catch |err| {
        std.log.err("conversation {s}: {t}", .{ reporter.id, err });
        try reporter.finish(.failed, failure_text(err), .{});
        return 1;
    };

    try reporter.finish(state_of(outcome.end), outcome.text, outcome.usage);

    return 0;
}

const stopped_late = "Stopped, as you asked. It was in the middle of a step that did not " ++
    "end on its own; what it had done is kept.";

const look_first = "Before you finish: you changed pages and have not looked at them " ++
    "since. Open each page you changed (the browser, else `show`), compare it with what " ++
    "was asked (and the reference, if there is one), fix what differs, then finish.";

const died = "The agent stopped unexpectedly, before it was done. Try again; if it " ++
    "happens again, its log is in data/agents/.";
const silent = "Nothing happened for 5 minutes (no word from the model, no step), so the " ++
    "turn was ended as stuck. What it did is kept. Try again.";

/// The turn runs in a worker process of its own. When the worker dies before it finishes
/// (a crash), the conversation is ended here as failed, so it never shows as working on.
fn supervise(
    init: std.process.Init,
    arena: std.mem.Allocator,
    db_path: []const u8,
    id: []const u8,
) !u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(db_path.len > 0);

    const executable = try std.process.executablePathAlloc(init.io, arena);
    // The server this turn runs under: a server started since carries the turn on itself.
    const started_under = try operator.find(init.io, arena, db_path);
    var child = try std.process.spawn(init.io, .{
        .argv = &.{ executable, "--db", db_path, "agent", "--conversation", id, "--worker" },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    var stopper: ?Stopper = if (started_under) |session| .{
        .io = init.io,
        .session = session,
        .id = id,
        .pid = child.id.?,
    } else null;

    if (stopper) |*watching| {
        try watching.start();
    }

    const term = try child.wait(init.io);

    if (stopper) |*watching| {
        watching.done.store(true, .release);
    }

    const ended_by_stop = if (stopper) |*watching| watching.ended_it.load(.acquire) else false;
    const finished = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };

    if (finished) {
        return 0;
    }

    std.log.err("conversation {s}: the agent ended with {any}", .{ id, term });

    const session = try operator.find(init.io, arena, db_path) orelse return 1;
    const restarted = if (started_under) |first|
        !std.mem.eql(u8, &first.key, &session.key)
    else
        false;

    if (restarted) {
        std.log.info("conversation {s}: the server restarted and carries it on", .{id});

        return 1;
    }

    var channel = Channel.of(init.io, arena, session);
    var reporter: Reporter = .{
        .channel = &channel,
        .id = id,
    };

    // Already over when the worker failed the turn itself: then this changes nothing.
    const fell_silent = switch (term) {
        .exited => |code| code == watchdog_module.exit_code,
        else => false,
    };

    const state: model_ai.State = if (ended_by_stop) .stopped else .failed;
    const why = if (ended_by_stop) stopped_late else if (fell_silent) silent else died;

    reporter.finish(state, why, .{}) catch |err| {
        std.log.info("conversation {s}: left as it was ({t})", .{ id, err });
    };

    return 1;
}

fn take_turn(
    init: std.process.Init,
    arena: std.mem.Allocator,
    db_path: []const u8,
    reporter: *Reporter,
    begun: Begun,
) !ai.Outcome {
    std.debug.assert(begun.prompt.len > 0);
    std.debug.assert(reporter.channel.token.len > 0);

    var answerers: Answerers = .{
        .init = init,
        .arena = arena,
        .db_path = db_path,
    };
    defer answerers.deinit();

    const inner = try answerers.provider_of(begun.provider);
    var drafter: Drafter = .{
        .channel = reporter.channel,
        .io = init.io,
        .id = reporter.id,
        .watchdog = reporter.watchdog,
    };

    reporter.drafter = &drafter;
    answerers.plugin.progress = drafter.progress();
    var activity: Activity = .{
        .channel = reporter.channel,
        .id = reporter.id,
    };
    var paced: Paced = .{
        .inner = inner,
        .io = init.io,
        .activity = &activity,
    };
    const provider = paced.provider();
    const folder = try std.fmt.allocPrint(arena, "{s}/agents/screens", .{
        std.fs.path.dirname(db_path) orelse ".",
    });
    const camera = Camera.find(init.io, folder, reporter.id);
    const session = reporter.channel.session;
    var browser: browser_module.Browser = .{
        .channel = reporter.channel,
        .io = init.io,
        .id = reporter.id,
    };
    const downloads = try downloads_of(init.io, arena, db_path);
    const crawl = try crawl_of(init.io, arena, downloads, begun.prompt);
    var tools: tools_module.Tools = .{
        .channel = reporter.channel,
        .browser = &browser,
        .activity = &activity,
        .downloads = downloads,
        .crawl = crawl,
        .reader = if (answerers.application != null) &answerers.plugin else null,
        .camera = if (camera) |*found| found else null,
        .site = if (session.url.len > 0)
            session.url
        else
            try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{session.port}),
    };
    // The last turn's own messages when they were kept, else rebuilt from the steps.
    const kept_path = try std.fmt.allocPrint(arena, "{s}/agents/{s}.history.json", .{
        std.fs.path.dirname(db_path) orelse ".",
        reporter.id,
    });
    const asks = history.asks_before(begun.history);
    const asked = try history.messages_of(arena, reporter.channel, .{
        .prompt = begun.prompt,
        .pictures = begun.pictures,
        .history = &.{},
    });
    const ask = try told_of_crawl(arena, asked, crawl);
    const messages = history.continued(arena, init.io, kept_path, asks, ask[0]) orelse
        try history.messages_of(arena, reporter.channel, .{
            .prompt = begun.prompt,
            .pictures = begun.pictures,
            .history = begun.history,
        });

    const turn_tools = try tools.of(arena);
    const outcome = try ai.run(arena, provider, turn_tools, reporter.observer(), messages, .{
        .model = begun.model,
        .system = try system_of(arena, reporter.channel),
        .steps_max = steps_max,
        // Within what every listed model writes in one reply; a provider that streams is
        // never timed out by a long one. One cut off there is carried on from.
        .output_tokens_max = 32_000,
        .effort = effort_module.effort_of(begun.prompt, asks > 0),
        .images_max = if (answerers.application == null or answerers.plugin.reads_pictures(arena))
            6
        else
            0,
    });

    history.keep(arena, init.io, kept_path, asks + 1, outcome.messages);

    return outcome;
}

/// Downloads into the media folder beside the database, made when missing. Kept in the
/// turn's arena: their threads may outlive this call.
fn downloads_of(
    io: std.Io,
    arena: std.mem.Allocator,
    db_path: []const u8,
) !*downloads_module.Downloads {
    std.debug.assert(db_path.len > 0);

    const folder = std.fs.path.dirname(db_path) orelse ".";
    const root = try std.fmt.allocPrint(arena, "{s}/media", .{folder});
    const downloads = try arena.create(downloads_module.Downloads);

    std.Io.Dir.cwd().createDirPath(io, root) catch |err| {
        std.log.warn("media folder: {t}", .{err});
    };
    downloads.* = .{
        .io = io,
        .root = root,
    };

    return downloads;
}

/// A site the ask names, read from now on with its files downloading; null for none.
fn crawl_of(
    io: std.Io,
    arena: std.mem.Allocator,
    downloads: *downloads_module.Downloads,
    prompt: []const u8,
) !?*Crawl {
    std.debug.assert(prompt.len > 0);

    const start = std.mem.indexOf(u8, prompt, "https://") orelse
        std.mem.indexOf(u8, prompt, "http://") orelse return null;
    const end = std.mem.indexOfAnyPos(u8, prompt, start, " \t\n\"'<>)") orelse prompt.len;
    const url = std.mem.trimEnd(u8, prompt[start..end], ".,;:!?");

    if (!downloads_module.public_url(url)) {
        return null;
    }

    const uri = std.Uri.parse(url) catch return null;
    const host = if (uri.host) |found| found.percent_encoded else return null;
    const crawl = try arena.create(Crawl);

    crawl.* = .{
        .io = io,
        .downloads = downloads,
        .start = url,
        .folder = try downloads_module.folder_of_host(arena, host),
    };
    try crawl.start_in_background();

    return crawl;
}

/// The ask, told that the site it names is being read and its files downloaded.
fn told_of_crawl(
    arena: std.mem.Allocator,
    asked: []const ai.Message,
    crawl: ?*Crawl,
) ![]const ai.Message {
    std.debug.assert(asked.len == 1);

    const site = crawl orelse return asked;
    const note = try std.fmt.allocPrint(arena, "(Publr: {s} is being read now, its pages " ++
        "and stylesheets, and every file they show is downloading into the media folder " ++
        "`{s}`. `download` says how far it got; `media sync` takes in what has arrived.)", .{
        site.start,
        site.folder,
    });
    const noted = [_]ai.Part{ai.Part.of_text(note)};
    const parts = try std.mem.concat(arena, ai.Part, &.{ asked[0].parts, &noted });
    const told = try arena.dupe(ai.Message, asked);

    told[0].parts = parts;

    return told;
}

/// The turn's system prompt, its command list fetched as the turn's device: what this
/// project has, its installed plugins' commands included.
fn system_of(arena: std.mem.Allocator, channel: *Channel) ![]const u8 {
    std.debug.assert(channel.token.len > 0);

    const answer = try channel.command(&.{"--commands"});
    const commands = if (answer.code == 0) answer.out else "";

    return tools_module.system_of(arena, commands);
}

/// What can answer a conversation: a script (`scripted`, from the file `PUBLR_AI_SCRIPT`
/// names: a JSON list of responses), or a provider plugin, run here with the project opened.
const Answerers = struct {
    init: std.process.Init,
    arena: std.mem.Allocator,
    db_path: []const u8,
    scripted: ai.Scripted = .{
        .responses = &.{},
    },
    application: ?*server.Server = null,
    plugin: PluginProvider = undefined,

    fn provider_of(answerers: *Answerers, name: []const u8) !ai.Provider {
        std.debug.assert(name.len > 0);
        std.debug.assert(answerers.application == null);

        if (std.mem.eql(u8, name, providers.scripted)) {
            return answerers.script();
        }

        const gpa = answerers.init.gpa;
        const application = try gpa.create(server.Server);
        errdefer gpa.destroy(application);

        const db_path = try answerers.arena.dupeZ(u8, answerers.db_path);

        try application.init(answerers.init, db_path);
        answerers.application = application;
        answerers.plugin = .{
            .application = application,
            .io = answerers.init.io,
            .name = try answerers.arena.dupe(u8, name),
        };

        return answerers.plugin.provider();
    }

    fn script(answerers: *Answerers) !ai.Provider {
        std.debug.assert(answerers.scripted.answered == 0);

        const init = answerers.init;
        const arena = answerers.arena;
        const path = environment.get(providers.script_variable) orelse {
            return error.ProviderNotFound;
        };
        const limit: std.Io.Limit = .limited(script_bytes_max);
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, limit);

        const Script = []const ai.Response;

        answerers.scripted.responses = try std.json.parseFromSliceLeaky(Script, arena, text, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });

        return answerers.scripted.provider();
    }

    fn deinit(answerers: *Answerers) void {
        std.debug.assert(answerers.db_path.len > 0);

        const application = answerers.application orelse return;

        answerers.plugin.streams.deinit();
        application.deinit();
        answerers.init.gpa.destroy(application);
        answerers.application = null;
    }
};

/// A scripted model answers at once; `PUBLR_AI_SCRIPT_PACE_MS` makes it wait before each
/// answer, so a demonstration can be watched.
const Paced = struct {
    inner: ai.Provider,
    io: std.Io,
    pace_ms: u32 = 0,
    /// Told before each reply is asked for.
    activity: ?*Activity = null,

    fn provider(paced: *Paced) ai.Provider {
        std.debug.assert(paced.pace_ms == 0);

        const text = environment.get("PUBLR_AI_SCRIPT_PACE_MS") orelse "0";

        paced.pace_ms = @min(std.fmt.parseInt(u32, text, 10) catch 0, 60_000);

        return .{
            .context = paced,
            .complete_fn = complete,
        };
    }

    fn complete(
        context: *anyopaque,
        arena: std.mem.Allocator,
        request: ai.Request,
    ) ai.Error!ai.Response {
        const paced: *Paced = @ptrCast(@alignCast(context));

        std.debug.assert(request.messages.len > 0);

        if (paced.activity) |activity| {
            activity.thinking();
        }

        if (paced.pace_ms > 0) {
            std.Io.sleep(paced.io, .fromMilliseconds(paced.pace_ms), .awake) catch |err| {
                std.log.warn("pace: {t}", .{err});
            };
        }

        return paced.retried(arena, request);
    }

    /// A provider that is down or limiting for a moment is asked again, after a wait that
    /// grows; any other failure, or the last of the waits, ends the turn as before.
    fn retried(paced: *Paced, arena: std.mem.Allocator, request: ai.Request) ai.Error!ai.Response {
        std.debug.assert(request.messages.len > 0);
        std.debug.assert(retry_waits_ms.len > 0);

        for (retry_waits_ms) |wait_ms| {
            const answer = paced.inner.complete(arena, request);

            if (answer) |response| {
                return response;
            } else |err| switch (err) {
                error.Unavailable, error.Limited => {},
                else => return err,
            }

            if (paced.activity) |activity| {
                activity.say("Waiting for the provider, then asking again");
            }

            std.Io.sleep(paced.io, .fromMilliseconds(wait_ms), .awake) catch |err| {
                std.log.warn("retry wait: {t}", .{err});
            };
        }

        return paced.inner.complete(arena, request);
    }
};

/// Between a provider's failed answer and the next try.
const retry_waits_ms = [_]u32{ 3_000, 10_000, 30_000 };

/// Why a turn failed, as the person reads it at the end of the conversation.
fn failure_text(err: anyerror) []const u8 {
    std.debug.assert(@errorName(err).len > 0);

    return switch (err) {
        error.KeyMissing => "The provider has no key yet: add it under Settings > AI.",
        error.KeyRejected => "The provider refused its key: check it under Settings > AI.",
        error.Limited => "The provider is limiting calls right now (too many, or out of " ++
            "credit). Try again in a while.",
        error.Unavailable => "The provider could not be reached, or failed. Try again.",
        error.ProviderNotFound => "The provider chosen is not installed any more: choose " ++
            "one under Settings > AI.",
        else => "Something went wrong while working on it.",
    };
}

fn state_of(end: ai.End) model_ai.State {
    std.debug.assert(@intFromEnum(end) <= @intFromEnum(ai.End.paused));

    return switch (end) {
        .finished, .length, .steps_exhausted => .finished,
        .stopped => .stopped,
        .refused => .failed,
        .paused => .waiting,
    };
}

/// Tells the server each step as it lands, and learns from its answer whether to go on.
const Reporter = struct {
    channel: *Channel,
    id: []const u8,
    go_on: bool = true,
    /// The words of the reply being written, while its provider streams them.
    drafter: ?*Drafter = null,
    /// Told of each step, so a turn that falls silent is ended.
    watchdog: ?*watchdog_module.Watchdog = null,
    /// The site page the agent last wrote, shown again once it puts its changes live.
    site_page: []const u8 = "",
    /// The last failed call, and how many times running it failed the same way.
    failed_hash: u64 = 0,
    failed_repeats: u32 = 0,
    /// Pages changed since the agent last looked at one; reminded once to look.
    unlooked: bool = false,
    reminded: bool = false,

    /// A write to an app links the page it becomes; putting the apps live, the last of them.
    fn site_href(reporter: *Reporter, call: ai.Part, href: []const u8) ![]const u8 {
        std.debug.assert(call.kind == .tool_call);

        const arena = reporter.channel.arena;
        const words = tools_module.args_of(arena, call.input) orelse return href;
        const apps = words.len >= 2 and std.mem.eql(u8, words[0], "apps");

        if (!apps) {
            return href;
        }

        if (std.mem.eql(u8, words[1], "load")) {
            return reporter.site_page;
        }

        const path = flag_of(words, "--path") orelse return href;

        if (!std.mem.eql(u8, words[1], "write")) {
            return href;
        }

        const page = try site_page_module.address_of(reporter.channel, arena, path) orelse {
            return href;
        };

        reporter.site_page = page;

        return page;
    }

    fn observer(reporter: *Reporter) ai.Observer {
        return .{
            .context = reporter,
            .step_fn = step,
            .stopped_fn = stopped,
            .finishing_fn = finishing,
        };
    }

    /// A turn that changed pages and never looked at them since is asked to, once.
    fn finishing(context: *anyopaque) ?[]const u8 {
        const reporter: *Reporter = @ptrCast(@alignCast(context));

        std.debug.assert(reporter.id.len > 0);

        if (!reporter.unlooked or reporter.reminded) {
            return null;
        }

        reporter.reminded = true;

        return look_first;
    }

    fn stopped(context: *anyopaque) bool {
        const reporter: *Reporter = @ptrCast(@alignCast(context));

        return !reporter.go_on;
    }

    fn step(context: *anyopaque, happened: ai.Step) anyerror!void {
        const reporter: *Reporter = @ptrCast(@alignCast(context));
        const arena = reporter.channel.arena;

        std.debug.assert(reporter.id.len > 0);

        if (reporter.watchdog) |watchdog| {
            watchdog.alive();
        }

        switch (happened) {
            .said => |response| {
                const text = try said_in(arena, response.parts);

                if (reporter.drafter) |drafter| {
                    drafter.reset();
                }

                // The last words are the conversation's answer, not a step.
                if (text.len > 0 and response.stop == .tool_calls) {
                    try reporter.record(.{
                        .kind = "said",
                        .summary = model_ai.summary_of(text),
                        .detail = text,
                    });
                }
            },
            .ran => |ran| {
                // The plan is shown as words, a checklist, not as a command that ran.
                if (std.mem.eql(u8, ran.call.name orelse "", "plan") and !ran.answer.failed) {
                    const checklist = ran.answer.output;

                    return reporter.record(.{
                        .kind = "said",
                        .summary = "Plan",
                        .detail = try std.mem.concat(arena, u8, &.{ "Plan:\n\n", checklist }),
                    });
                }

                const shown = try shown_of(arena, ran.call, ran.answer.output);
                const href = if (ran.answer.failed)
                    shown.href
                else
                    try reporter.site_href(ran.call, shown.href);

                try reporter.record(.{
                    .kind = "ran",
                    .summary = model_ai.clipped(shown.label, model_ai.summary_len_max),
                    .detail = ran.answer.output,
                    .failed = ran.answer.failed,
                    .href = href,
                });
                try reporter.runaway(arena, ran.call, ran.answer, shown.label);
                reporter.noted(arena, ran.call, ran.answer.failed);
            },
        }
    }

    /// Whether the pages changed (a write or load of the apps) or were looked at (`show`,
    /// the browser) since: what `finishing` asks about.
    fn noted(reporter: *Reporter, arena: std.mem.Allocator, call: ai.Part, failed: bool) void {
        std.debug.assert(call.kind == .tool_call);

        const name = call.name orelse return;

        if (failed) {
            return;
        }

        if (std.mem.eql(u8, name, "show") or std.mem.eql(u8, name, "browser")) {
            reporter.unlooked = false;
            return;
        }

        const words = tools_module.args_of(arena, call.input) orelse return;
        const changes = [_][]const u8{ "write", "load", "remove" };

        if (!std.mem.eql(u8, name, "run") or words.len < 2 or !std.mem.eql(u8, words[0], "apps")) {
            return;
        }

        for (changes) |verb| {
            if (std.mem.eql(u8, words[1], verb)) {
                reporter.unlooked = true;
            }
        }
    }

    /// A call failing the same way again and again is a turn going nowhere: it ends, and
    /// says so. Anything else in between starts the count again.
    fn runaway(
        reporter: *Reporter,
        arena: std.mem.Allocator,
        call: ai.Part,
        answer: ai.Answer,
        label: []const u8,
    ) !void {
        std.debug.assert(call.kind == .tool_call);
        std.debug.assert(repeats_max > 1);

        if (!answer.failed) {
            reporter.failed_repeats = 0;
            return;
        }

        const input = if (call.input) |value|
            try std.json.Stringify.valueAlloc(arena, value, .{})
        else
            "";
        var hasher = std.hash.Wyhash.init(0);

        hasher.update(call.name orelse "");
        hasher.update(input);
        hasher.update(answer.output[0..@min(answer.output.len, 512)]);

        const hash = hasher.final();

        const again = hash == reporter.failed_hash;

        reporter.failed_repeats = if (again) reporter.failed_repeats + 1 else 1;
        reporter.failed_hash = hash;

        if (reporter.failed_repeats < repeats_max) {
            return;
        }

        const note = try std.fmt.allocPrint(arena, "Stopped: \u{201c}{s}\u{201d} failed the " ++
            "same way {d} times in a row, so trying it again would not help. What it said: {s}", .{
            label,
            reporter.failed_repeats,
            model_ai.clipped(answer.output, 600),
        });

        try reporter.record(.{
            .kind = "said",
            .summary = model_ai.summary_of(note),
            .detail = note,
        });
        reporter.go_on = false;
    }

    const Line = struct {
        kind: []const u8,
        summary: []const u8,
        detail: []const u8,
        failed: bool = false,
        href: []const u8 = "",
    };

    fn record(reporter: *Reporter, line: Line) !void {
        std.debug.assert(line.kind.len > 0);
        std.debug.assert(reporter.id.len > 0);

        const detail = model_ai.clipped(line.detail, model_ai.detail_len_max);
        const failed = if (line.failed) "true" else "false";
        const args = [_][]const u8{
            "--as-admin", "ai",       "step",    "--id",
            reporter.id,  "--kind",   line.kind, "--summary",
            line.summary, "--detail", detail,    "--failed",
            failed,       "--href",   line.href,
        };
        const recorded = try reporter.channel.operate(Recorded, &args);

        reporter.go_on = recorded.go_on;
    }

    fn finish(
        reporter: *Reporter,
        state: model_ai.State,
        answer: []const u8,
        usage: ai.Usage,
    ) !void {
        std.debug.assert(state.over());
        std.debug.assert(reporter.id.len > 0);

        const arena = reporter.channel.arena;
        const input = try std.fmt.allocPrint(arena, "{d}", .{usage.input_tokens});
        const output = try std.fmt.allocPrint(arena, "{d}", .{usage.output_tokens});
        const cached = try std.fmt.allocPrint(arena, "{d}", .{usage.cached_tokens});
        const args = [_][]const u8{
            "--as-admin",     "ai",              "finish",
            "--id",           reporter.id,       "--state",
            @tagName(state),  "--answer",        model_ai.clipped(answer, model_ai.answer_len_max),
            "--input_tokens", input,             "--output_tokens",
            output,           "--cached_tokens", cached,
        };

        _ = try reporter.channel.operate(struct {}, &args);
    }
};

/// A removal on the person's list: its words, and the list to show.
fn listed_of(arena: std.mem.Allocator, said: []const u8) !presented.Presented {
    std.debug.assert(std.mem.startsWith(u8, said, listed_marker));

    const words_end = std.mem.indexOf(u8, said, ". Not removed") orelse said.len;
    const words = said[listed_marker.len..words_end];
    const path_start = std.mem.indexOf(u8, said, "(/admin/removals/") orelse return .{
        .label = try std.fmt.allocPrint(arena, "To remove: {s}", .{words}),
    };
    const path_end = std.mem.indexOfScalarPos(u8, said, path_start, ')') orelse said.len;

    return .{
        .label = try std.fmt.allocPrint(arena, "To remove: {s}", .{words}),
        .href = said[path_start + 1 .. path_end],
    };
}

/// The text among a response's parts, joined.
fn said_in(arena: std.mem.Allocator, parts: []const ai.Part) ![]const u8 {
    std.debug.assert(parts.len <= std.math.maxInt(u32));

    var text: std.ArrayList(u8) = .empty;

    for (parts) |part| {
        if (part.kind == .text and part.text != null) {
            try text.appendSlice(arena, part.text.?);
        }
    }

    return text.items;
}

/// A call as a person follows it: what it did, and the page that shows it.
/// What a removal the agent ran says: it is on the person's list, not removed.
const listed_marker = "Listed for removal: ";

fn shown_of(arena: std.mem.Allocator, call: ai.Part, output: []const u8) !presented.Presented {
    std.debug.assert(call.kind == .tool_call);

    if (std.mem.indexOf(u8, output, listed_marker)) |start| {
        return listed_of(arena, output[start..]);
    }

    if (std.mem.eql(u8, call.name orelse "", "guide")) {
        return .{
            .label = "Read the guide for building on Publr",
        };
    }

    if (std.mem.eql(u8, call.name orelse "", "fetch")) {
        const url = tools_module.url_of(call.input) orelse return .{
            .label = "Read a web page",
        };
        const host = (std.Uri.parse(url) catch return .{
            .label = "Read a web page",
        }).host;
        const name = if (host) |found| switch (found) {
            .raw, .percent_encoded => |text| text,
        } else url;

        if (!tools_module.a_page(url)) {
            const file = std.fs.path.basename(tools_module.path_part(url));

            const label = try std.fmt.allocPrint(arena, "Read {s} from {s}", .{ file, name });

            return .{
                .label = label,
            };
        }

        return .{
            .label = try std.fmt.allocPrint(arena, "Read {s}", .{name}),
            .href = url,
        };
    }

    if (std.mem.eql(u8, call.name orelse "", "browser")) {
        return .{
            .label = try browser_module.label_of(arena, call.input),
        };
    }

    if (std.mem.eql(u8, call.name orelse "", "download")) {
        return .{
            .label = "Looked at the downloads",
        };
    }

    if (std.mem.eql(u8, call.name orelse "", "show")) {
        const path = tools_module.path_of(call.input) orelse return .{
            .label = "Show a page",
        };

        return .{
            .label = try std.fmt.allocPrint(arena, "Opened {s}", .{path}),
            .href = path,
        };
    }

    const words = tools_module.args_of(arena, call.input) orelse return .{
        .label = "Ran publr",
    };
    const presented_step = try presented.present(arena, words, output);
    const shown = try with_fields(arena, presented_step, words);

    // A removal that kept its copy in the trash: the step undoes it.
    if (trash_entry_of(output)) |entry| {
        return .{
            .label = try std.fmt.allocPrint(arena, "{s} (in the trash)", .{shown.label}),
            .href = try std.fmt.allocPrint(arena, "/admin/trash?entry={s}", .{entry}),
        };
    }

    return shown;
}

/// A record's save, linked with the fields it wrote (`#fields=title,intro`), so the preview
/// shows each of them changing.
fn with_fields(
    arena: std.mem.Allocator,
    shown: presented.Presented,
    words: []const []const u8,
) !presented.Presented {
    std.debug.assert(words.len <= tools_module.args_max);

    const saves = words.len > 2 and std.mem.eql(u8, words[0], "record") and
        (std.mem.eql(u8, words[1], "save") or std.mem.eql(u8, words[1], "update"));

    if (!saves or shown.href.len == 0 or std.mem.indexOfScalar(u8, shown.href, '#') != null) {
        return shown;
    }

    const document = document_of(words) orelse return shown;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, document, .{}) catch {
        return shown;
    };
    const fields = switch (parsed) {
        .object => |object| object.keys(),
        else => return shown,
    };

    if (fields.len == 0) {
        return shown;
    }

    const joined = try std.mem.join(arena, ",", fields[0..@min(fields.len, 8)]);

    return .{
        .label = shown.label,
        .href = try std.fmt.allocPrint(arena, "{s}#fields={s}", .{ shown.href, joined }),
    };
}

/// The `--document` a command's words carry.
fn document_of(words: []const []const u8) ?[]const u8 {
    std.debug.assert(words.len <= tools_module.args_max);

    return flag_of(words, "--document");
}

/// The value after `name` among a command's words.
fn flag_of(words: []const []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(words.len <= tools_module.args_max);
    std.debug.assert(name.len > 2);

    for (words, 0..) |word, index| {
        if (std.mem.eql(u8, word, name) and index + 1 < words.len) {
            return words[index + 1];
        }
    }

    return null;
}

/// The trash entry a removal answered with (`"trash": "<id>"`), if it kept one.
fn trash_entry_of(output: []const u8) ?[]const u8 {
    std.debug.assert(output.len <= std.math.maxInt(u32));

    const marker = "\"trash\": \"";
    const start = (std.mem.indexOf(u8, output, marker) orelse return null) + marker.len;
    const end = std.mem.indexOfScalarPos(u8, output, start, '"') orelse return null;
    const entry = output[start..end];

    return if (entry.len > 0 and entry.len <= 64) entry else null;
}
test {
    _ = downloads_module;
    _ = @import("agent/crawl.zig");
    _ = effort_module;
    _ = @import("agent/stopper.zig");
    _ = tools_module;
    _ = browser_module;
    _ = @import("agent/activity.zig");
}
