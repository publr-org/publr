//! The `download` tool: files from the web into the media folder in the background, and how
//! far the downloads (and a site's crawl) have got.

const std = @import("std");
const ai = @import("../../lib/ai.zig");
const Downloads = @import("downloads.zig").Downloads;
const Crawl = @import("crawl.zig").Crawl;

pub const description = "Download files from the web into the media folder in the " ++
    "background (images, SVGs, fonts, video, audio, documents), while you go on working: " ++
    "give `urls` and the `folder` they go in. Without `urls`, says how far the downloads " ++
    "have got. Then `media sync` takes in every file that has arrived at once, in that " ++
    "folder; use them from there. Far faster than importing one by one.";

pub const schema =
    \\{"type":"object","properties":{
    \\"urls":{"type":"array","items":{"type":"string"},"description":"The files' addresses"},
    \\"folder":{"type":"string","description":"The media folder they go in, lowercase"}}}
;

pub fn run(
    arena: std.mem.Allocator,
    downloads: *Downloads,
    crawl: ?*Crawl,
    input: ?std.json.Value,
) !ai.Answer {
    std.debug.assert(downloads.root.len > 0);

    const object = if (input) |value| switch (value) {
        .object => |object| object,
        else => null,
    } else null;
    const folder = folder_of(object);
    var queued: u32 = 0;

    if (object) |found| {
        if (found.get("urls")) |urls| {
            if (urls == .array) {
                for (urls.array.items[0..@min(urls.array.items.len, 400)]) |url| {
                    if (url == .string and downloads.add(url.string, folder)) {
                        queued += 1;
                    }
                }
            }
        }
    }

    const status = try downloads.status(arena);
    const crawled = if (crawl) |site| try std.fmt.allocPrint(arena, "\nThe site's crawl: {d} " ++
        "pages read{s}.", .{
        site.read.load(.monotonic),
        if (site.done.load(.acquire)) ", done" else ", still reading",
    }) else "";

    return .{
        .output = try std.fmt.allocPrint(arena, "Queued {d}. {s}{s}", .{ queued, status, crawled }),
    };
}

fn folder_of(object: ?std.json.ObjectMap) []const u8 {
    std.debug.assert(@sizeOf(std.json.ObjectMap) > 0);

    const given = (object orelse return "downloads").get("folder") orelse return "downloads";

    if (given != .string or given.string.len == 0 or given.string.len > 60) {
        return "downloads";
    }

    for (given.string) |char| {
        const kept = std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-' or
            char == '_';

        if (!kept) {
            return "downloads";
        }
    }

    return given.string;
}
