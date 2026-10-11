//! A site to move, read before the model has planned anything: from its home page, the
//! pages it links to on its own host and their stylesheets, every file the front end shows
//! (images and their variants, SVGs, icons, video and audio, posters, fonts, documents) goes
//! into the background downloads at once. Runs in a thread of its own; the turn goes on.

const std = @import("std");
const timed = @import("../../operations/http_timed.zig");
const downloads_module = @import("downloads.zig");

const Downloads = downloads_module.Downloads;

/// Pages read, at most; stylesheets read, at most.
const pages_max: u32 = 40;
const sheets_max: u32 = 40;
/// One page or stylesheet read, at most.
const text_bytes_max: u32 = 4 << 20;

/// What the front end can show, by the end of its path: kept, or skipped by the library
/// with its reason.
const media_extensions = [_][]const u8{
    ".jpg", ".jpeg", ".png",   ".gif", ".webp", ".avif", ".svg",  ".ico", ".bmp",
    ".mp4", ".webm", ".mov",   ".m4v", ".ogv",  ".mp3",  ".wav",  ".ogg", ".m4a",
    ".pdf", ".doc",  ".docx",  ".xls", ".xlsx", ".ppt",  ".pptx", ".odt", ".zip",
    ".csv", ".woff", ".woff2", ".ttf", ".otf",
};
const page_extensions = [_][]const u8{ "", ".html", ".htm", ".php", ".asp", ".aspx" };
/// Attributes whose values name files or pages.
const attributes = [_][]const u8{
    "src=",  "srcset=", "data-src=", "data-srcset=", "data-bg=", "poster=", "href=", "content=",
    "data=",
};

pub const Crawl = struct {
    io: std.Io,
    downloads: *Downloads,
    /// The site's home page, and the folder its files go into.
    start: []const u8,
    folder: []const u8,
    pages: std.ArrayList([]const u8) = .empty,
    sheets: std.ArrayList([]const u8) = .empty,
    /// Pages read so far; whole once `done`.
    read: std.atomic.Value(u32) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    pub fn start_in_background(crawl: *Crawl) !void {
        std.debug.assert(crawl.start.len > 0);
        std.debug.assert(crawl.folder.len > 0);

        const thread = try std.Thread.spawn(.{}, run, .{crawl});

        thread.detach();
    }

    fn run(crawl: *Crawl) void {
        std.debug.assert(pages_max > 0);

        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();

        const arena = arena_state.allocator();

        crawl.pages.append(arena, crawl.start) catch return crawl.done.store(true, .release);

        var index: u32 = 0;

        while (index < crawl.pages.items.len and index < pages_max) : (index += 1) {
            const page = crawl.pages.items[index];
            const html = get(crawl.io, arena, page) orelse continue;

            crawl.collect(arena, page, html);
            _ = crawl.read.fetchAdd(1, .monotonic);
        }

        for (crawl.sheets.items[0..@min(crawl.sheets.items.len, sheets_max)]) |sheet| {
            const css = get(crawl.io, arena, sheet) orelse continue;

            crawl.collect_css(arena, sheet, css);
        }

        crawl.done.store(true, .release);
    }

    /// Every file and page a page names, sorted into downloads, stylesheets and pages.
    fn collect(crawl: *Crawl, arena: std.mem.Allocator, page: []const u8, html: []const u8) void {
        std.debug.assert(page.len > 0);

        for (attributes) |attribute| {
            var at: usize = 0;
            var found: u32 = 0;

            while (found < 10_000) : (found += 1) {
                const start = std.mem.indexOfPos(u8, html, at, attribute) orelse break;
                const value = quoted(html, @intCast(start + attribute.len)) orelse {
                    at = start + attribute.len;
                    continue;
                };

                at = start + attribute.len + value.len;
                crawl.named(arena, page, value, std.mem.indexOf(u8, attribute, "srcset") != null);
            }
        }

        crawl.collect_css(arena, page, html);
    }

    /// One attribute's value: a list of candidates in a srcset, else one address.
    fn named(
        crawl: *Crawl,
        arena: std.mem.Allocator,
        page: []const u8,
        value: []const u8,
        set: bool,
    ) void {
        std.debug.assert(page.len > 0);

        if (!set) {
            return crawl.sort(arena, page, value);
        }

        var candidates = std.mem.splitScalar(u8, value, ',');
        var taken: u32 = 0;

        while (candidates.next()) |candidate| : (taken += 1) {
            if (taken > 32) break;

            const trimmed = std.mem.trim(u8, candidate, " \t\n");
            const end = std.mem.indexOfAny(u8, trimmed, " \t\n") orelse trimmed.len;

            crawl.sort(arena, page, trimmed[0..end]);
        }
    }

    /// `url(...)` in a stylesheet or a page's styles: fonts, backgrounds.
    fn collect_css(
        crawl: *Crawl,
        arena: std.mem.Allocator,
        base: []const u8,
        css: []const u8,
    ) void {
        std.debug.assert(base.len > 0);

        var at: usize = 0;
        var found: u32 = 0;

        while (found < 10_000) : (found += 1) {
            const start = std.mem.indexOfPos(u8, css, at, "url(") orelse break;
            const end = std.mem.indexOfScalarPos(u8, css, start, ')') orelse break;
            const inner = std.mem.trim(u8, css[start + 4 .. end], " \t\n'\"");

            at = end;

            if (!std.mem.startsWith(u8, inner, "data:")) {
                crawl.sort(arena, base, inner);
            }
        }
    }

    /// An address found on `base`: a file to download, a stylesheet to read, a page of the
    /// same site to read, or nothing.
    fn sort(crawl: *Crawl, arena: std.mem.Allocator, base: []const u8, raw: []const u8) void {
        std.debug.assert(base.len > 0);

        const skip = raw.len == 0 or raw[0] == '#' or std.mem.startsWith(u8, raw, "mailto:") or
            std.mem.startsWith(u8, raw, "tel:") or std.mem.startsWith(u8, raw, "javascript:") or
            std.mem.startsWith(u8, raw, "data:");

        if (skip) {
            return;
        }

        const url = resolved(arena, base, raw) orelse return;
        const ending = ending_of(url);

        if (std.mem.eql(u8, ending, ".css")) {
            return add_once(arena, &crawl.sheets, url, sheets_max);
        }

        for (media_extensions) |extension| {
            if (std.mem.eql(u8, ending, extension)) {
                _ = crawl.downloads.add(url, crawl.folder);
                return;
            }
        }

        if (!same_host(url, crawl.start)) {
            return;
        }

        for (page_extensions) |extension| {
            if (std.mem.eql(u8, ending, extension)) {
                return add_once(arena, &crawl.pages, url, pages_max);
            }
        }
    }
};

fn add_once(
    arena: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    url: []const u8,
    max: u32,
) void {
    std.debug.assert(max > 0);

    const bare = url[0 .. std.mem.indexOfScalar(u8, url, '#') orelse url.len];

    if (list.items.len >= max) {
        return;
    }

    for (list.items) |item| {
        if (std.mem.eql(u8, std.mem.trimEnd(u8, item, "/"), std.mem.trimEnd(u8, bare, "/"))) {
            return;
        }
    }

    list.append(arena, bare) catch return;
}

/// A page's or stylesheet's text; null when it does not answer.
fn get(io: std.Io, arena: std.mem.Allocator, url: []const u8) ?[]const u8 {
    std.debug.assert(url.len > 0);

    const result = timed.fetch(io, arena, .{
        .url = url,
        .body_max = text_bytes_max,
    }, timed.timeout_ms) catch return null;

    if (result.status != .ok) {
        return null;
    }

    return result.body;
}

/// The value of an attribute, quoted with `"` or `'`, starting at `at`.
fn quoted(text: []const u8, at: u32) ?[]const u8 {
    std.debug.assert(at <= text.len);

    if (at >= text.len or (text[at] != '"' and text[at] != '\'')) {
        return null;
    }

    const end = std.mem.indexOfScalarPos(u8, text, at + 1, text[at]) orelse return null;

    return text[at + 1 .. end];
}

/// `raw` resolved against `base`, as a whole address; null when it is not one.
fn resolved(arena: std.mem.Allocator, base: []const u8, raw: []const u8) ?[]const u8 {
    std.debug.assert(base.len > 0);

    if (raw.len > 2048) {
        return null;
    }

    const base_uri = std.Uri.parse(base) catch return null;
    const buffer = arena.alloc(u8, raw.len * 2 + base.len + 64) catch return null;
    var aux: []u8 = buffer;

    @memcpy(buffer[0..raw.len], std.mem.trim(u8, raw, " "));

    const trimmed_len = std.mem.trim(u8, raw, " ").len;
    const uri = base_uri.resolveInPlace(trimmed_len, &aux) catch return null;
    var out: std.Io.Writer.Allocating = .init(arena);

    uri.format(&out.writer) catch return null;

    return out.written();
}

/// The end of an address's path from its last dot, lowercase: `.jpg`, or empty for none.
fn ending_of(url: []const u8) []const u8 {
    std.debug.assert(url.len > 0);

    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const name = std.fs.path.basename(url[0..end]);
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    const ending = name[dot..];

    for (ending) |char| {
        if (std.ascii.isUpper(char)) {
            return lowered_endings(ending);
        }
    }

    return ending;
}

fn lowered_endings(ending: []const u8) []const u8 {
    std.debug.assert(ending.len > 0);

    for (media_extensions ++ page_extensions ++ [_][]const u8{".css"}) |known| {
        if (std.ascii.eqlIgnoreCase(known, ending)) {
            return known;
        }
    }

    return ending;
}

fn same_host(url: []const u8, start: []const u8) bool {
    std.debug.assert(start.len > 0);

    const one = std.Uri.parse(url) catch return false;
    const other = std.Uri.parse(start) catch return false;
    const one_host = if (one.host) |host| host.percent_encoded else return false;
    const other_host = if (other.host) |host| host.percent_encoded else return false;

    return std.ascii.eqlIgnoreCase(without_www(one_host), without_www(other_host));
}

fn without_www(host: []const u8) []const u8 {
    std.debug.assert(host.len <= 255);

    return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
}

test "a page's files, stylesheets and pages are told apart" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "https://a.pl/img/x.jpg",
        resolved(arena, "https://a.pl/o-firmie/", "../img/x.jpg").?,
    );
    try std.testing.expectEqualStrings(".jpg", ending_of("https://a.pl/A.JPG?v=1"));
    try std.testing.expectEqualStrings("", ending_of("https://a.pl/kontakt/"));
    try std.testing.expect(same_host("https://www.a.pl/x", "https://a.pl/"));
    try std.testing.expectEqualStrings("a b.png", quoted("src=\"a b.png\"", 4).?);
}
