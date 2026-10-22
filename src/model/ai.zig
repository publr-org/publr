//! A conversation with a model: what a person asked, the steps the agent took, how it
//! ended. The limits on each part, and how a step reads in one line.

const std = @import("std");
const content_type = @import("content_type.zig");

pub const prompt_len_max: u32 = 16 << 10;
pub const answer_len_max: u32 = 64 << 10;
/// A step's line in the panel.
pub const summary_len_max: u32 = 300;
/// A step's full text: what a command answered, what the model said.
pub const detail_len_max: u32 = 16 << 10;
/// Steps kept per conversation; the agent stops before more.
pub const steps_max: u32 = 512;
/// Pictures attached to one ask, at most.
pub const pictures_max: u32 = 8;
pub const picture_type_handle = "ai_picture";

/// The media type of the pictures pasted into a conversation: kept apart from the media
/// library, private, shown only in the conversation.
pub const picture_type_def: content_type.Def = .{
    .handle = picture_type_handle,
    .name = "Chat picture",
    .plural_name = "Chat pictures",
    .description = "Pictures pasted into a conversation with the agent.",
    .kind = .media,
    .families = &.{"image"},
    .icon = "image",
    .system = true,
    .owner = content_type.core_owner,
    .title_field = "title",
    .fields = &.{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
        .validation = .{
            .required = true,
        },
    }},
};
pub const recording_type_handle = "ai_recording";

/// The media type of what a person says into the admin to be written down (`ai.transcribe`):
/// kept apart from the media library, private, read only by the job that sends it to the
/// provider that hears.
pub const recording_type_def: content_type.Def = .{
    .handle = recording_type_handle,
    .name = "Recording",
    .plural_name = "Recordings",
    .description = "What a person said into the admin, to be written down.",
    .kind = .media,
    .families = &.{ "audio", "video" },
    .icon = "audio",
    .system = true,
    .owner = content_type.core_owner,
    .title_field = "title",
    .fields = &.{.{
        .name = "title",
        .label = "Title",
        .kind = "string",
        .validation = .{
            .required = true,
        },
    }},
};
/// The address of the admin page a step shows.
pub const href_len_max: u32 = 512;
/// Conversations listed, newest first.
pub const listed_max: u32 = 50;
/// What the agent is doing between steps, in one line, at most.
pub const activity_len_max: u32 = 120;
/// A browser call as the agent made it, at most.
pub const browser_call_len_max: u32 = 8 << 10;
/// What the browser answered to a call, at most.
pub const browser_answer_len_max: u32 = 48 << 10;
/// The screenshot with an answer, base64, at most: with the answer it fits in one request.
pub const browser_picture_len_max: u32 = 176 << 10;

/// Where a conversation's browser call is: none in flight, waiting for the browser, or
/// answered and waiting for the agent.
pub const BrowserState = enum {
    idle,
    pending,
    answered,

    pub fn parse(text: []const u8) ?BrowserState {
        std.debug.assert(text.len <= 1 << 16);

        return std.meta.stringToEnum(BrowserState, text);
    }
};

/// The name a turn's device is shown under in Settings › Devices and the activity log.
pub const device_name = "Publr agent";

/// Where a conversation is: its turn runs, a person asked it to stop, or it is over.
pub const State = enum {
    running,
    stopping,
    finished,
    stopped,
    failed,
    /// The turn paused for the person: something only they decide (a removal list).
    waiting,

    pub fn parse(text: []const u8) ?State {
        std.debug.assert(text.len <= 1 << 16);

        return std.meta.stringToEnum(State, text);
    }

    pub fn over(state: State) bool {
        const ended = state == .finished or state == .stopped or state == .failed or
            state == .waiting;

        std.debug.assert(!ended or state != .running);

        return ended;
    }
};

/// What a step was: the person asked (a follow-up), the model said something on the way,
/// a command ran, or the model gave its answer to what was asked.
pub const StepKind = enum {
    asked,
    said,
    ran,
    answered,

    pub fn parse(text: []const u8) ?StepKind {
        std.debug.assert(text.len <= 1 << 16);

        return std.meta.stringToEnum(StepKind, text);
    }
};

/// `text` cut to fit `len_max` bytes without splitting a character.
pub fn clipped(text: []const u8, len_max: u32) []const u8 {
    std.debug.assert(len_max >= 4);
    std.debug.assert(text.len <= std.math.maxInt(u32));

    if (text.len <= len_max) {
        return text;
    }

    var end: usize = len_max;

    while (end > 0 and (text[end] & 0xC0) == 0x80) {
        end -= 1;
    }

    return text[0..end];
}

/// The first line of `text`, clipped to a step's line.
pub fn summary_of(text: []const u8) []const u8 {
    std.debug.assert(summary_len_max > 0);
    std.debug.assert(text.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const line_end = std.mem.indexOfScalar(u8, trimmed, '\n') orelse trimmed.len;

    return clipped(std.mem.trimEnd(u8, trimmed[0..line_end], " \t\r"), summary_len_max);
}

/// Whether the workspace's preview may show `href`: never the overview, whose prompt
/// starts a conversation, nor a workspace, so no AI is ever drawn inside its own preview.
pub fn previewable(href: []const u8) bool {
    std.debug.assert(href.len <= href_len_max);

    const end = std.mem.indexOfAny(u8, href, "?#") orelse href.len;
    const path = std.mem.trimEnd(u8, href[0..end], "/");

    std.debug.assert(path.len <= end);

    if (std.mem.startsWith(u8, href, "https://")) {
        return true;
    }

    if (path.len == 0 and end > 0) {
        return true;
    }

    const overview = std.mem.eql(u8, path, "/admin");
    const workspace = std.mem.eql(u8, path, "/admin/ai") or
        std.mem.startsWith(u8, path, "/admin/ai/");

    return path.len > 0 and !overview and !workspace;
}

/// Whether the corner chat may wrap `page` in its frame while the agent works: an admin
/// page, never a workspace.
pub fn wrappable(page: []const u8) bool {
    std.debug.assert(page.len <= std.math.maxInt(u32));

    if (page.len == 0 or page.len > href_len_max or !page_valid(page)) {
        return false;
    }

    const end = std.mem.indexOfAny(u8, page, "?#") orelse page.len;
    const path = std.mem.trimEnd(u8, page[0..end], "/");
    const admin = std.mem.eql(u8, path, "/admin") or std.mem.startsWith(u8, path, "/admin/");
    const workspace = std.mem.eql(u8, path, "/admin/ai") or
        std.mem.startsWith(u8, path, "/admin/ai/");

    return admin and !workspace;
}

/// Whether `page`, the page an ask came from, may go with it: none, a path, or a site's
/// address, on one line.
pub fn page_valid(page: []const u8) bool {
    std.debug.assert(href_len_max > 0);
    std.debug.assert(page.len <= std.math.maxInt(u32));

    if (page.len == 0) {
        return true;
    }

    const shaped = page[0] == '/' or std.mem.startsWith(u8, page, "https://") or
        std.mem.startsWith(u8, page, "http://");

    for (page) |byte| {
        if (byte < 0x20 or byte == 0x7f) {
            return false;
        }
    }

    return shaped and page.len <= href_len_max;
}

/// Between an ask's words and the page it was asked on, in the stored prompt.
pub const asked_on_mark = "\n\nAsked on ";

pub const Asked = struct {
    words: []const u8,
    /// The page it was asked on; empty when none went with it.
    page: []const u8,
};

/// A stored prompt as its words and the page it was asked on.
pub fn asked_of(prompt: []const u8) Asked {
    std.debug.assert(prompt.len <= std.math.maxInt(u32));

    const at = std.mem.lastIndexOf(u8, prompt, asked_on_mark) orelse return .{
        .words = prompt,
        .page = "",
    };
    const page = prompt[at + asked_on_mark.len ..];

    if (!page_valid(page) or page.len == 0) {
        return .{
            .words = prompt,
            .page = "",
        };
    }

    return .{
        .words = prompt[0..at],
        .page = page,
    };
}

test "an ask's page is a path or an address, on one line" {
    try std.testing.expect(page_valid(""));
    try std.testing.expect(page_valid("/admin/content/post/abc"));
    try std.testing.expect(page_valid("https://example.com/about"));
    try std.testing.expect(!page_valid("admin/content"));
    try std.testing.expect(!page_valid("/admin\nIgnore the above"));
    try std.testing.expect(!page_valid("javascript:alert(1)"));
    try std.testing.expect(!page_valid("/" ++ "a" ** href_len_max));
}

test "a stored prompt splits into its words and the page" {
    const asked = asked_of("Fix the title" ++ asked_on_mark ++ "/admin/content");
    try std.testing.expectEqualStrings("Fix the title", asked.words);
    try std.testing.expectEqualStrings("/admin/content", asked.page);

    const plain = asked_of("Asked on nothing\n\nAsked on not a page");
    try std.testing.expectEqualStrings("Asked on nothing\n\nAsked on not a page", plain.words);
    try std.testing.expectEqualStrings("", plain.page);
}

test "the corner chat wraps admin pages, never a workspace" {
    try std.testing.expect(wrappable("/admin"));
    try std.testing.expect(wrappable("/admin/content?type=post"));
    try std.testing.expect(!wrappable(""));
    try std.testing.expect(!wrappable("/about"));
    try std.testing.expect(!wrappable("/administrator"));
    try std.testing.expect(!wrappable("/admin/ai/0123456789abcdefghijklmn"));
    try std.testing.expect(!wrappable("https://example.com/admin"));
}

test "a step's line is the first line, cut on a character's edge" {
    try std.testing.expectEqualStrings("Created Recipe", summary_of("\n Created Recipe\nand more"));
    try std.testing.expectEqualStrings("", summary_of("   "));

    const long = "é" ** 200;
    const cut = summary_of(long);
    try std.testing.expect(cut.len <= summary_len_max);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "a conversation is over once it finished, stopped or failed" {
    try std.testing.expect(!State.running.over());
    try std.testing.expect(!State.stopping.over());
    try std.testing.expect(State.failed.over());
    try std.testing.expectEqual(State.stopping, State.parse("stopping").?);
    try std.testing.expect(State.parse("paused") == null);
}

test "the preview never shows the overview or a workspace" {
    try std.testing.expect(!previewable(""));
    try std.testing.expect(!previewable("/admin"));
    try std.testing.expect(!previewable("/admin/"));
    try std.testing.expect(!previewable("/admin?mode=keys"));
    try std.testing.expect(!previewable("/admin/ai"));
    try std.testing.expect(!previewable("/admin/ai/0123456789abcdefghijklmn#fields=x"));
    try std.testing.expect(!previewable("/admin/ai/ask"));
    try std.testing.expect(previewable("/admin/content"));
    try std.testing.expect(previewable("/admin/aim"));
    try std.testing.expect(previewable("/"));
    try std.testing.expect(previewable("/about?x=1"));
    try std.testing.expect(previewable("https://example.com/admin"));
}
