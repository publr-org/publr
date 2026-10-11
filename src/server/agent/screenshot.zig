//! A web page as a visitor's screen shows it, for the model to look at: the Chrome on this
//! machine takes it headless, in a profile of its own, and it goes on as a JPEG. Without a
//! Chrome there is no picture, and the agent reads the page's words alone.

const std = @import("std");
const builtin = @import("builtin");
const ai = @import("../../lib/ai.zig");
const image = @import("../../lib/image.zig");
const environment = @import("../../lib/environment.zig");

/// A desktop visitor's screen, a little taller: the first screen and what follows it.
pub const width: u32 = 1280;
pub const height: u32 = 1560;
pub const wait_s: u32 = 30;
const png_bytes_max: u32 = 32 << 20;
const quality: u8 = 70;

/// Names the browser to use when it is not where it usually is.
pub const chrome_variable = "PUBLR_CHROME";

const known: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
    },
    .linux => &.{
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/snap/bin/chromium",
    },
    else => &.{},
};

pub const Camera = struct {
    io: std.Io,
    chrome: []const u8,
    /// Where pictures are taken, and where Chrome keeps its profile, apart from anyone's.
    folder: []const u8,
    /// The picture's file name: the conversation's id.
    name: []const u8,

    /// The browser on this machine; null when there is none.
    pub fn find(io: std.Io, folder: []const u8, name: []const u8) ?Camera {
        std.debug.assert(folder.len > 0);
        std.debug.assert(name.len > 0 and name.len <= 64);

        const cwd = std.Io.Dir.cwd();

        if (environment.get(chrome_variable)) |path| {
            cwd.access(io, path, .{}) catch return null;

            return .{
                .io = io,
                .chrome = path,
                .folder = folder,
                .name = name,
            };
        }

        for (known) |path| {
            if (cwd.access(io, path, .{})) |_| {
                return .{
                    .io = io,
                    .chrome = path,
                    .folder = folder,
                    .name = name,
                };
            } else |_| {
                continue;
            }
        }

        return null;
    }

    /// `url` as the screen shows it once it has loaded.
    pub fn take(camera: *const Camera, arena: std.mem.Allocator, url: []const u8) !ai.Image {
        std.debug.assert(url.len > 0);
        std.debug.assert(camera.chrome.len > 0);

        const io = camera.io;
        const cwd = std.Io.Dir.cwd();
        const shot = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ camera.folder, camera.name });

        try cwd.createDirPath(io, camera.folder);

        const argv = [_][]const u8{
            camera.chrome,
            "--headless=new",
            "--disable-gpu",
            "--hide-scrollbars",
            "--no-first-run",
            "--no-default-browser-check",
            "--mute-audio",
            try std.fmt.allocPrint(arena, "--user-data-dir={s}/chrome", .{camera.folder}),
            std.fmt.comptimePrint("--window-size={d},{d}", .{ width, height }),
            "--virtual-time-budget=8000",
            try std.fmt.allocPrint(arena, "--screenshot={s}", .{shot}),
            url,
        };
        cwd.deleteFile(io, shot) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        // Chrome writes the picture and may then linger: it is closed once the file is there.
        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        defer child.kill(io);

        try wait_for(io, shot);

        const png = try cwd.readFileAlloc(io, shot, arena, .limited(png_bytes_max));

        cwd.deleteFile(io, shot) catch |err| std.log.warn("screenshot left behind: {t}", .{err});

        return jpeg_of(arena, png);
    }
};

/// Until `path` is written: it has a size, the same a moment later.
fn wait_for(io: std.Io, path: []const u8) !void {
    std.debug.assert(path.len > 0);
    std.debug.assert(wait_s > 0);

    const cwd = std.Io.Dir.cwd();
    var size_seen: u64 = 0;
    var poll: u32 = 0;

    while (poll < wait_s * 4) : (poll += 1) {
        try std.Io.sleep(io, .fromMilliseconds(250), .awake);

        const size = if (cwd.statFile(io, path, .{})) |stat| stat.size else |_| 0;

        if (size > 0 and size == size_seen) {
            return;
        }

        size_seen = size;
    }

    return error.ScreenshotTimedOut;
}

/// A picture as the model takes it: a JPEG, base64.
pub fn jpeg_of(arena: std.mem.Allocator, bytes: []const u8) !ai.Image {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(quality > 0 and quality <= 100);

    const processed = try image.process(arena, bytes, .{
        .format = .jpeg,
        .quality = quality,
    });
    const encoder = std.base64.standard.Encoder;
    const data = try arena.alloc(u8, encoder.calcSize(processed.bytes.len));

    _ = encoder.encode(data, processed.bytes);

    return .{
        .media_type = "image/jpeg",
        .data = data,
    };
}

test "a picture goes to the model as a JPEG, base64" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const png = try @import("../../lib/image/encode.zig").sample_png(arena, 64, 40);
    const picture = try jpeg_of(arena, png);

    try std.testing.expectEqualStrings("image/jpeg", picture.media_type);
    try std.testing.expect(std.mem.startsWith(u8, picture.data, "/9j/"));
}
