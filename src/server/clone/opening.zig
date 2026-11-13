//! A page `publr` opens for its person: in Publr Studio when it is installed (its own link,
//! `publr-studio://open?url=`), else in the default browser. Nothing opens on a machine with
//! no opener; the address is printed either way.
const std = @import("std");
const builtin = @import("builtin");

const studio_app = "Publr Studio";
const studio_link = "publr-studio://open?url=";

pub fn open(init: std.process.Init, address: []const u8) void {
    std.debug.assert(address.len > 0);
    std.debug.assert(std.mem.startsWith(u8, address, "http"));

    switch (builtin.os.tag) {
        .macos => {
            const arena = init.arena.allocator();

            if (ran(init, &.{ "open", "-Ra", studio_app })) {
                const link = studio_address(arena, address) catch return;

                if (ran(init, &.{ "open", link })) {
                    return;
                }
            }

            _ = ran(init, &.{ "open", address });
        },
        .linux => {
            const display = init.environ_map.get("DISPLAY") != null or
                init.environ_map.get("WAYLAND_DISPLAY") != null;

            if (display) {
                _ = ran(init, &.{ "xdg-open", address });
            }
        },
        else => {},
    }
}

pub fn studio_address(arena: std.mem.Allocator, address: []const u8) ![]const u8 {
    std.debug.assert(address.len > 0);

    var link: std.Io.Writer.Allocating = .init(arena);

    try link.writer.writeAll(studio_link);
    try std.Uri.Component.percentEncode(&link.writer, address, std.ascii.isAlphanumeric);

    return link.written();
}

fn ran(init: std.process.Init, argv: []const []const u8) bool {
    std.debug.assert(argv.len > 0);

    var child = std.process.spawn(init.io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(init.io) catch return false;

    return term == .exited and term.exited == 0;
}

test "Studio is asked with the page's address, encoded whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const page = "http://admin.localhost:8170/admin/sync";
    const made = try studio_address(arena_state.allocator(), page);

    try std.testing.expectEqualStrings(
        "publr-studio://open?url=http%3A%2F%2Fadmin%2Elocalhost%3A8170%2Fadmin%2Fsync",
        made,
    );
}
