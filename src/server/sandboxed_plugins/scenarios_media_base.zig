//! Where media addresses start, changed by an installed plugin through the mod `media.base`:
//! the test plugin `mirror` keeps an origin and answers it, read from its own record.
const std = @import("std");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const registry = @import("../registry.zig");
const media = @import("../../operations/media.zig");
const media_view = @import("../../operations/media/view.zig");
const files_module = @import("../../lib/files.zig");
const encode = @import("../../lib/image/encode.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const module = @embedFile("sandboxed_plugin_mirror");

test "an installed plugin starts every media address at the origin it keeps" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    _ = try scenarios_remotes.put(&scenario, "mirror.wasm", module);
    try scenarios_remotes.enable(&scenario, "mirror");

    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const arena = scenario.harness.fixed.allocator();
    const root = try temporary.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var disk = try files_module.Disk.open(std.testing.io, root);
    defer disk.close();
    var system = scenario.ctx(.system);
    system.files = .{
        .disk = &disk,
    };
    try system.files.?.write(.incoming, "upload0001", try encode.sample_png(arena, 8, 4));

    // Nothing kept yet: the modifier leaves the base as it is, the site's own.
    const uploaded = try registry.SDK.dispatch(&system, media.Upload, .{
        .upload = "upload0001",
        .filename = "harbour.png",
    });
    const own = try std.fmt.allocPrint(arena, "/media/{s}", .{uploaded.key});

    try std.testing.expectEqualStrings(own, uploaded.url);
    try std.testing.expectEqualStrings(own, try viewed_url(&scenario, uploaded.id));

    _ = try scenario.call(admin, "mirror.set", "{\"origin\":\"https://cdn.example.test/\"}");

    const elsewhere = try std.fmt.allocPrint(arena, "https://cdn.example.test/media/{s}", .{
        uploaded.key,
    });

    try std.testing.expectEqualStrings(elsewhere, try viewed_url(&scenario, uploaded.id));

    var listing = scenario.ctx(admin);
    const listed = try registry.SDK.dispatch(&listing, media.List, .{});

    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings(elsewhere, listed.items[0].url);

    // An answer that is not an address of the web is left out.
    _ = try scenario.call(admin, "mirror.set", "{\"origin\":\"javascript:alert(1)\"}");
    try std.testing.expectEqualStrings(own, try viewed_url(&scenario, uploaded.id));
}

fn viewed_url(scenario: *Scenario, id: []const u8) ![]const u8 {
    std.debug.assert(id.len > 0);

    var reading = scenario.ctx(.anonymous);
    const viewed = try registry.SDK.dispatch(&reading, media_view.View, .{
        .id = id,
    });

    std.debug.assert(std.mem.endsWith(u8, viewed.url, viewed.key));

    return viewed.url;
}
