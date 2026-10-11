//! The `browser` tool: the person's own Chrome, lent through the Publr extension. Each call
//! waits on the conversation for the workspace page to hand it over and answer.

const std = @import("std");
const ai = @import("../../lib/ai.zig");
const Channel = @import("channel.zig").Channel;
const model_ai = @import("../../model/ai.zig");

/// How often the agent asks whether the browser answered.
const poll_ms: u32 = 300;
/// How long a call waits when no workspace ever said it has the extension: the page may
/// still be opening, but a turn with no browser should not wait on one.
const unready_wait_ms: u32 = 3_000;
/// How long a call waits on a browser that is there: a slow page, a long script.
const ready_wait_ms: u32 = 60_000;

pub const actions = [_][]const u8{
    "tabs",       "navigate", "screenshot", "read_page", "find",       "page_text", "click",
    "type",       "key",      "scroll",     "hover",     "form_input", "console",   "network",
    "javascript",
};

pub const description = "Use the person's own Chrome, through the Publr extension, in a " ++
    "tab group of its own the person watches: open pages (this site's and any other), " ++
    "screenshot them, read them as a tree of elements with refs, click and type by ref, " ++
    "read the console and network. Works only when the person's browser is connected; " ++
    "the first call says when it is not. On other sites than this one it only looks: " ++
    "navigate, screenshot, read_page, find, page_text, scroll. Actions: tabs (lists them; " ++
    "with url opens a new one), navigate (url, or back / forward), screenshot, read_page " ++
    "(filter: interactive for controls only), find (query), page_text, click (ref or " ++
    "coordinate), type (text, into the focused element or ref), key (text: Enter, " ++
    "Tab, cmd+a), scroll (direction, amount), hover, form_input (ref, value), console " ++
    "(pattern), network, javascript (code, this site only). Every action takes `tab`; " ++
    "without it, the tab last used.";

pub const schema =
    \\{"type":"object","properties":{
    \\"action":{"type":"string","enum":["tabs","navigate","screenshot","read_page","find",
    \\"page_text","click","type","key","scroll","hover","form_input","console","network",
    \\"javascript"]},
    \\"tab":{"type":"integer","description":"The tab, by the id `tabs` lists"},
    \\"url":{"type":"string","description":"An address, or back / forward"},
    \\"ref":{"type":"string","description":"An element, by the ref read_page or find gave"},
    \\"coordinate":{"type":"array","items":{"type":"integer"},
    \\"description":"[x, y] in the screenshot's pixels, when there is no ref"},
    \\"text":{"type":"string","description":"What to type, or the key to press"},
    \\"value":{"type":"string","description":"form_input's value"},
    \\"query":{"type":"string","description":"find: what to look for, in words"},
    \\"filter":{"type":"string","enum":["all","interactive"]},
    \\"direction":{"type":"string","enum":["up","down","left","right"]},
    \\"amount":{"type":"integer","description":"scroll: how far, in steps of a wheel"},
    \\"pattern":{"type":"string","description":"console: only messages matching it"},
    \\"code":{"type":"string","description":"javascript: an expression, its value answered"}},
    \\"required":["action"]}
;

const not_connected = "The person's browser is not connected (the Publr extension is " ++
    "not in their workspace): use `show` and `fetch` instead for the rest of this turn.";
const no_action = "`action` must be one of: tabs, navigate, screenshot, read_page, find, " ++
    "page_text, click, type, key, scroll, hover, form_input, console, network, javascript";

pub const Browser = struct {
    channel: *Channel,
    io: std.Io,
    /// The conversation the calls wait on.
    id: []const u8,
    /// The browser went away during this turn: later calls answer at once.
    gone: bool = false,

    pub fn run(browser: *Browser, arena: std.mem.Allocator, input: ?std.json.Value) !ai.Answer {
        std.debug.assert(browser.id.len > 0);
        std.debug.assert(browser.channel.token.len > 0);

        if (action_of(input) == null) {
            return .{
                .output = no_action,
                .failed = true,
            };
        }

        if (browser.gone) {
            return .{
                .output = not_connected,
                .failed = true,
            };
        }

        const call = try std.json.Stringify.valueAlloc(arena, input.?, .{});
        const asked = try browser.channel.operate(Asked, &.{
            "--as-admin", "ai", "browse", "--id", browser.id, "--call", call,
        });

        return browser.wait(arena, asked.number);
    }

    fn wait(browser: *Browser, arena: std.mem.Allocator, number: u32) !ai.Answer {
        std.debug.assert(number > 0);
        std.debug.assert(poll_ms < unready_wait_ms);

        const number_text = try std.fmt.allocPrint(arena, "{d}", .{number});
        var waited_ms: u32 = 0;

        while (waited_ms <= ready_wait_ms) : (waited_ms += poll_ms) {
            try std.Io.sleep(browser.io, .fromMilliseconds(poll_ms), .awake);

            const read = try browser.channel.operate(Browsed, &.{
                "--as-admin", "ai", "browsed", "--id", browser.id, "--number", number_text,
            });

            if (std.mem.eql(u8, read.state, "answered")) {
                return answer_of(arena, read);
            }

            const pending = std.mem.eql(u8, read.state, "pending");
            const unready_too_long = !read.ready and waited_ms >= unready_wait_ms;

            if (!pending or unready_too_long) {
                break;
            }
        }

        _ = try browser.channel.operate(Browsed, &.{
            "--as-admin", "ai",        "browsed",   "--id", browser.id,
            "--number",   number_text, "--give_up", "true",
        });
        browser.gone = true;

        return .{
            .output = not_connected,
            .failed = true,
        };
    }
};

const Asked = struct {
    number: u32,
};

const Browsed = struct {
    state: []const u8,
    ready: bool = false,
    answer: []const u8 = "",
    failed: bool = false,
    picture: []const u8 = "",
};

fn answer_of(arena: std.mem.Allocator, read: Browsed) !ai.Answer {
    std.debug.assert(std.mem.eql(u8, read.state, "answered"));
    std.debug.assert(read.picture.len <= model_ai.browser_picture_len_max);

    const output = if (read.answer.len > 0) read.answer else "Done.";

    if (read.picture.len == 0) {
        return .{
            .output = output,
            .failed = read.failed,
        };
    }

    const picture: ai.Image = .{
        .media_type = "image/jpeg",
        .data = read.picture,
    };

    return .{
        .output = output,
        .failed = read.failed,
        .images = try arena.dupe(ai.Image, &.{picture}),
    };
}

/// A call's action, when it names one of `actions`.
pub fn action_of(input: ?std.json.Value) ?[]const u8 {
    std.debug.assert(actions.len > 0);

    const object = switch (input orelse return null) {
        .object => |object| object,
        else => return null,
    };
    const action = switch (object.get("action") orelse return null) {
        .string => |text| text,
        else => return null,
    };

    for (actions) |known| {
        if (std.mem.eql(u8, known, action)) {
            return known;
        }
    }

    return null;
}

fn string_of(input: ?std.json.Value, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(input != null);

    const field = input.?.object.get(name) orelse return null;

    return switch (field) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

/// A call as the person follows it in the conversation.
pub fn label_of(arena: std.mem.Allocator, input: ?std.json.Value) ![]const u8 {
    std.debug.assert(actions.len > 0);

    const action = action_of(input) orelse return "Used the browser";
    const words = [_][2][]const u8{
        .{ "screenshot", "Took a screenshot" },
        .{ "read_page", "Read the page" },
        .{ "page_text", "Read the page's text" },
        .{ "click", "Clicked in the page" },
        .{ "scroll", "Scrolled the page" },
        .{ "hover", "Pointed at an element" },
        .{ "form_input", "Filled in a field" },
        .{ "console", "Read the console" },
        .{ "network", "Read the network requests" },
        .{ "javascript", "Ran a script in the page" },
    };

    for (words) |pair| {
        if (std.mem.eql(u8, pair[0], action)) {
            return pair[1];
        }
    }

    const url = string_of(input, "url");
    const text = string_of(input, "text") orelse "";
    const shown = text[0..@min(text.len, 40)];

    if (std.mem.eql(u8, action, "navigate") or std.mem.eql(u8, action, "tabs")) {
        const place = url orelse return "Looked at the tabs";

        return std.fmt.allocPrint(arena, "Opened {s}", .{host_of(place)});
    }

    if (std.mem.eql(u8, action, "find")) {
        const query = string_of(input, "query") orelse "";

        return std.fmt.allocPrint(arena, "Looked for \u{201c}{s}\u{201d}", .{
            query[0..@min(query.len, 60)],
        });
    }

    if (std.mem.eql(u8, action, "key")) {
        return std.fmt.allocPrint(arena, "Pressed {s}", .{shown});
    }

    return std.fmt.allocPrint(arena, "Typed \u{201c}{s}\u{201d}", .{shown});
}

/// An address's host, or the address itself when it has none (`back`).
fn host_of(url: []const u8) []const u8 {
    std.debug.assert(url.len > 0);

    const start = (std.mem.indexOf(u8, url, "://") orelse return url) + 3;
    const end = std.mem.indexOfAnyPos(u8, url, start, "/?#") orelse url.len;

    return if (end > start) url[start..end] else url;
}

test "a browser call names a known action, and reads as a line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parse = struct {
        fn of(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
            return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
        }
    }.of;

    const opened = try parse(arena, "{\"action\":\"navigate\",\"url\":\"https://a.eu/x?y\"}");
    try std.testing.expectEqualStrings("navigate", action_of(opened).?);
    try std.testing.expectEqualStrings("Opened a.eu", try label_of(arena, opened));

    const typed = try parse(arena, "{\"action\":\"type\",\"text\":\"hello\"}");
    try std.testing.expectEqualStrings("Typed \u{201c}hello\u{201d}", try label_of(arena, typed));

    const unknown = try parse(arena, "{\"action\":\"download\"}");
    try std.testing.expect(action_of(unknown) == null);
    try std.testing.expect(action_of(null) == null);
    try std.testing.expectEqualStrings("back", host_of("back"));

    const parsed = try parse(arena, schema);
    try std.testing.expect(parsed.object.get("required") != null);
}
