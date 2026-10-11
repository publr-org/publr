//! A model provider, as a plugin registers one: two operations, `<plugin>.describe_provider`
//! (who it is, its models, how its key is made) and `<plugin>.complete` (a request in, a
//! response out, both as `publr_ai`'s JSON). Core finds every provider installed by those
//! names, lists them under Settings › AI, and has a conversation's agent call the one
//! chosen. A provider calls its model through `http.fetch`, its key written
//! `{secret:NAME}`, so it never holds the key.
//!
//! ```zig
//! pub const operations = [_]type{
//!     publr.ai.Describe("example_ai", .{ .id = "example_ai", .label = "Example", ... }),
//!     publr.ai.Complete("example_ai", complete),
//! };
//!
//! fn complete(ctx: *PluginCtx, request: publr.ai.Request) publr.sdk.Error!publr.ai.Response {
//!     // Turn the request into the model's own, send it with http.fetch, read its answer.
//! }
//! ```

const std = @import("std");
const lib_ai = @import("../lib/ai.zig");
const operation = @import("operation.zig");
const Grant = @import("grant.zig").Grant;
const PluginCtx = @import("plugin/context.zig").PluginCtx;
const ProgressCtx = @import("context.zig").Ctx;

pub const Role = lib_ai.Role;
pub const Part = lib_ai.Part;
pub const Message = lib_ai.Message;
pub const Tool = lib_ai.Tool;
pub const Request = lib_ai.Request;
pub const Response = lib_ai.Response;
pub const Usage = lib_ai.Usage;
pub const Stop = lib_ai.Stop;
pub const Description = lib_ai.Description;
pub const Model = lib_ai.Model;
pub const Key = lib_ai.Key;
pub const request_of = lib_ai.request_of;
pub const request_json = lib_ai.request_json;
pub const response_of = lib_ai.response_of;
pub const response_json = lib_ai.response_json;

/// What a provider's API said went wrong, from its error answer: the `message` of its
/// `error` (`{"error":{"message":"API key is invalid."}}`, the shape most share), else the
/// answer's start.
pub fn error_message(arena: std.mem.Allocator, body: []const u8) []const u8 {
    std.debug.assert(body.len <= std.math.maxInt(u32));

    const Shape = struct {
        @"error": struct {
            message: []const u8 = "",
        } = .{},
    };
    const start = whole_characters(body, 300);
    const parsed = std.json.parseFromSliceLeaky(Shape, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return start;

    return if (parsed.@"error".message.len > 0) parsed.@"error".message else start;
}

pub const describe_verb = "describe_provider";
pub const read_verb = "read_page";

/// What a page reads as, at most: the model reads it, not a person.
pub const page_text_len_max: u32 = 48 << 10;

/// `<plugin>.read_page`: a web page a conversation's agent was asked to look at, read
/// through `http.fetch` (so only where the plugin may send requests: an AI provider asks
/// for any address, `*`) and turned into text. A plain GET: no secret is ever filled in.
pub fn Read(comptime plugin: []const u8) type {
    return struct {
        pub const name = plugin ++ "." ++ read_verb;
        pub const description = "Read a web page as text, for a conversation's agent";
        pub const details =
            \\A plain GET of `url` (https), its scripts, styles and markup left out, each link
            \\kept as its text with its address; up to 48 KiB. The local operator's alone: a
            \\conversation's agent calls it.
        ;
        pub const kind: operation.Kind = .read;
        pub const operator_only = true;
        pub const In = struct {
            url: []const u8,
        };
        pub const Out = struct {
            status: u16,
            text: []const u8,
        };
        pub const example: In = .{
            .url = "https://example.com/",
        };
        pub const example_out: Out = .{
            .status = 200,
            .text = "Example Domain ...",
        };
        pub const field_docs: operation.Docs(In) = .{
            .url = "The page's address, https",
        };

        pub fn run(ctx: *PluginCtx, in: In, granted: *const Grant) operation.Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(in.url.len > 0);

            if (std.mem.indexOf(u8, in.url, "{secret:") != null) {
                return error.Invalid;
            }

            const Fetch = @import("../operations/http.zig").Fetch;
            const answer = try ctx.call(Fetch, .{
                .url = in.url,
                .headers = &.{.{
                    .name = "User-Agent",
                    .value = "Publr (reading a page)",
                }},
            });
            const text = text_of_html(ctx.arena(), answer.body) catch return error.OutOfMemory;

            return .{
                .status = answer.status,
                .text = text,
            };
        }
    };
}

pub const Progress = struct {
    pub const name = "ai.progress";
    pub const plugins_only = true;
    pub const description = "Pass on a model's words as it writes them";
    pub const details =
        \\What a provider plugin calls while it reads a reply as a stream: `words` are the
        \\ones written since its last call. The person watching sees them at once. Plugins
        \\granted `ai.progress` only; nothing happens where no turn listens.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        words: []const u8,
    };
    pub const Out = struct {};
    pub const example: In = .{
        .words = "I'll start with the home page",
    };
    pub const example_out: Out = .{};
    pub const field_docs: operation.Docs(In) = .{
        .words = "The words since the last call",
    };

    pub fn run(ctx: *ProgressCtx, in: In, granted: *const Grant) operation.Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.words.len <= std.math.maxInt(u32));

        if (ctx.caller != .plugin) {
            return error.Denied;
        }

        const progress = ctx.progress orelse return .{};

        progress.said(progress.context, in.words);

        return .{};
    }
};

/// A stream of server-sent events, fed as it arrives: each whole `data:` line handed on,
/// a line cut between two pieces kept until its end comes. How a provider reads a reply
/// it streams (`http.stream`, `http.read`).
pub const Events = struct {
    pending: std.ArrayList(u8) = .empty,

    /// Hands each whole `data:` line in `piece` (after what was pending) to `on_data`.
    pub fn feed(
        events: *Events,
        arena: std.mem.Allocator,
        piece: []const u8,
        context: anytype,
        comptime on_data: fn (@TypeOf(context), []const u8) anyerror!void,
    ) !void {
        std.debug.assert(piece.len <= std.math.maxInt(u32));

        try events.pending.appendSlice(arena, piece);

        var start: usize = 0;

        while (std.mem.indexOfScalarPos(u8, events.pending.items, start, '\n')) |end| {
            const line = std.mem.trimEnd(u8, events.pending.items[start..end], "\r");

            start = end + 1;

            if (std.mem.startsWith(u8, line, "data:")) {
                try on_data(context, std.mem.trimStart(u8, line["data:".len..], " "));
            }
        }

        const rest = events.pending.items.len - start;

        std.mem.copyForwards(u8, events.pending.items[0..rest], events.pending.items[start..]);
        events.pending.shrinkRetainingCapacity(rest);
    }
};

/// An HTML page as text a model reads: scripts and styles left out, tags gone, a link's
/// address after its text, an image and a stylesheet as their addresses, runs of white
/// space one space or one line.
pub fn text_of_html(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    std.debug.assert(html.len <= std.math.maxInt(u32));

    var text: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    var link: []const u8 = "";

    while (index < html.len and text.items.len < page_text_len_max) {
        if (html[index] != '<') {
            // A line break in the source is a space, as the page shows it.
            const char = if (html[index] == '\n') ' ' else html[index];

            try add_char(arena, &text, char);
            index += 1;
            continue;
        }

        const end = std.mem.indexOfScalarPos(u8, html, index, '>') orelse break;
        const tag = html[index + 1 .. end];

        index = end + 1;

        if (starts_tag(tag, "script") or starts_tag(tag, "style")) {
            const close = if (starts_tag(tag, "script")) "</script" else "</style";

            index = std.ascii.indexOfIgnoreCasePos(html, index, close) orelse html.len;
        } else if (starts_tag(tag, "a ")) {
            link = attribute(tag, "href");
        } else if (starts_tag(tag, "img ")) {
            const said = .{ attribute(tag, "alt"), attribute(tag, "src") };

            try text.print(arena, " [image: {s} ({s})] ", said);
        } else if (starts_tag(tag, "link ") and std.mem.indexOf(u8, tag, "stylesheet") != null) {
            try text.print(arena, "[stylesheet ({s})]\n", .{attribute(tag, "href")});
        } else if (starts_tag(tag, "/a") and link.len > 0) {
            try text.print(arena, " ({s})", .{link});
            link = "";
        } else if (block(tag)) {
            try add_char(arena, &text, '\n');
        }
    }

    return std.mem.trim(u8, whole_characters(text.items, page_text_len_max), " \n");
}

/// `text` up to `len_max` bytes, never cut inside a character.
fn whole_characters(text: []const u8, len_max: u32) []const u8 {
    std.debug.assert(len_max > 0);

    if (text.len <= len_max) {
        return text;
    }

    var end: usize = len_max;

    while (end > 0 and (text[end] & 0xC0) == 0x80) {
        end -= 1;
    }

    return text[0..end];
}

fn add_char(arena: std.mem.Allocator, text: *std.ArrayList(u8), char: u8) !void {
    std.debug.assert(text.items.len <= page_text_len_max + 64);

    const space = char == ' ' or char == '\t' or char == '\r';
    const last: u8 = if (text.items.len > 0) text.items[text.items.len - 1] else '\n';

    if (char == '\n') {
        if (last == ' ') {
            text.items[text.items.len - 1] = '\n';
        } else if (last != '\n') {
            try text.append(arena, '\n');
        }

        return;
    }

    if (space) {
        if (last != ' ' and last != '\n') {
            try text.append(arena, ' ');
        }

        return;
    }

    try text.append(arena, char);
}

fn starts_tag(tag: []const u8, name: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(tag, name);
}

fn block(tag: []const u8) bool {
    std.debug.assert(tag.len <= std.math.maxInt(u32));

    const names = [_][]const u8{
        "p",       "/p",       "br",     "div",    "/div", "li", "h1", "h2", "h3", "h4", "tr",
        "section", "/section", "header", "footer", "nav",
    };

    for (names) |name| {
        const exact = std.ascii.eqlIgnoreCase(tag, name);
        const opening = tag.len > name.len and starts_tag(tag, name) and
            (tag[name.len] == ' ' or tag[name.len] == '/');

        if (exact or opening) {
            return true;
        }
    }

    return false;
}

fn attribute(tag: []const u8, name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);

    const at = std.mem.indexOf(u8, tag, name) orelse return "";
    const rest = tag[at + name.len ..];

    if (rest.len < 2 or rest[0] != '=') {
        return "";
    }

    const quote = rest[1];

    if (quote != '"' and quote != '\'') {
        return "";
    }

    const end = std.mem.indexOfScalarPos(u8, rest, 2, quote) orelse return "";

    return rest[2..end];
}
pub const complete_verb = "complete";

/// `<plugin>.describe_provider`: who the provider is, what models it offers, how its key is
/// made. Anyone may read it; it holds nothing secret.
pub fn Describe(comptime plugin: []const u8, comptime about: Description) type {
    comptime std.debug.assert(about.id.len > 0);

    return struct {
        pub const name = plugin ++ "." ++ describe_verb;
        pub const description = "What " ++ about.label ++ " offers as a model provider";
        pub const details =
            \\Its models, the one used when none is chosen, and how its key is made and kept.
            \\Core reads it to list the provider under Settings > AI.
        ;
        pub const kind: operation.Kind = .read;
        pub const open = true;
        pub const In = struct {};
        pub const Out = Description;
        pub const example: In = .{};
        pub const example_out: Out = about;

        pub fn run(ctx: *PluginCtx, in: In, granted: *const Grant) operation.Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.now_ms() >= 0);

            _ = in;

            return about;
        }
    };
}

/// The JSON `complete` takes and answers.
pub const Completion = struct {
    pub const In = struct {
        request: []const u8,
    };
    pub const Out = struct {
        response: []const u8,
    };
};

/// `<plugin>.complete`: one call to the model. `answer` gets the request parsed and turns
/// the model's reply into a response.
pub fn Complete(
    comptime plugin: []const u8,
    comptime answer: fn (ctx: *PluginCtx, request: Request) operation.Error!Response,
) type {
    return struct {
        pub const name = plugin ++ "." ++ complete_verb;
        pub const description = "One call to the model: a request in, a response out";
        pub const details =
            \\`request` and `response` are JSON in publr_ai's shape: messages of text, tool
            \\calls and tool results; the model's parts, why it stopped and what it cost. The
            \\local operator's alone: a conversation's agent calls it.
        ;
        pub const kind: operation.Kind = .read;
        pub const operator_only = true;
        pub const In = Completion.In;
        pub const Out = Completion.Out;
        pub const example: In = .{
            .request = "{\"messages\":[{\"role\":\"user\",\"parts\":" ++
                "[{\"kind\":\"text\",\"text\":\"Hi\"}]}]}",
        };
        pub const example_out: Out = .{
            .response = "{\"parts\":[{\"kind\":\"text\",\"text\":\"Hello\"}],\"stop\":\"end\"}",
        };
        pub const field_docs: operation.Docs(In) = .{
            .request = "The request, as JSON",
        };

        pub fn run(ctx: *PluginCtx, in: In, granted: *const Grant) operation.Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(in.request.len > 0);

            const arena = ctx.arena();
            const request = request_of(arena, in.request) catch return error.Invalid;
            const response = try answer(ctx, request);
            const text = response_json(arena, response) catch return error.OutOfMemory;

            return .{
                .response = text,
            };
        }
    };
}

test "a page reads as its text and links, without scripts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const html = "<html><head><style>p{}</style><script>var x=1;</script></head><body>" ++
        "<h1>Eko Laguna</h1><p>Rooms   by the\n lake.</p><a href=\"/contact\">Contact</a></body>";
    const text = try text_of_html(arena_state.allocator(), html);

    try std.testing.expectEqualStrings("Eko Laguna\nRooms by the lake.\nContact (/contact)", text);
}

test "a page's images and stylesheets read as their addresses" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const html = "<link rel=\"stylesheet\" href=\"/app/main.css\"><p>Hi " ++
        "<img alt=\"Logo\" src=\"/uploads/logo.png\"></p>";
    const text = try text_of_html(arena_state.allocator(), html);

    try std.testing.expect(std.mem.indexOf(u8, text, "[stylesheet (/app/main.css)]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[image: Logo (/uploads/logo.png)]") != null);
}

test "server-sent events are handed on a whole line at a time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const Seen = struct {
        lines: std.ArrayList([]const u8) = .empty,
        arena: std.mem.Allocator,

        fn on(seen: *@This(), data: []const u8) anyerror!void {
            try seen.lines.append(seen.arena, try seen.arena.dupe(u8, data));
        }
    };

    var seen: Seen = .{
        .arena = arena_state.allocator(),
    };
    var events: Events = .{};

    try events.feed(seen.arena, "event: a\ndata: {\"x\":", &seen, Seen.on);
    try events.feed(seen.arena, "1}\r\n\ndata: [DONE]\n", &seen, Seen.on);

    try std.testing.expectEqual(@as(usize, 2), seen.lines.items.len);
    try std.testing.expectEqualStrings("{\"x\":1}", seen.lines.items[0]);
    try std.testing.expectEqualStrings("[DONE]", seen.lines.items[1]);
}
