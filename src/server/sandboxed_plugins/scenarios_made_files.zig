//! Files an installed plugin makes, on the test plugin `invoicer`: an invoice's PDF written
//! in pieces (larger than one), kept as a private file of its own media type, served
//! through the link it signed; another plugin neither makes files of its type nor reads them.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../registry.zig");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");
const files_module = @import("../../lib/files.zig");
const media = @import("../../operations/media.zig");
const link = @import("../../operations/link.zig");
const store = @import("../../store.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;
const invoicer = @embedFile("sandboxed_plugin_invoicer");
const made = media.made;

const Issued = struct {
    file: []const u8,
    size: u64,
    link: []const u8,
};

test "an installed plugin makes a file in pieces, kept private, opened by its link alone" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const root = try scenario.temporary.dir.realPathFileAlloc(
        std.testing.io,
        ".",
        std.testing.allocator,
    );
    defer std.testing.allocator.free(root);

    var disk = try files_module.Disk.open(std.testing.io, root);
    defer disk.close();

    const files: files_module.Files = .{
        .disk = &disk,
    };

    _ = try scenarios_remotes.put(&scenario, "invoicer.wasm", invoicer);
    try scenarios_remotes.enable(&scenario, "invoicer");

    var issuing = scenario.ctx(admin);

    issuing.files = files;

    const arena = scenario.harness.fixed.allocator();
    const answer = try registry.SDK.call_json(&issuing, "invoicer.issue", "{\"number\":\"FK-1\"}");
    const issued = try std.json.parseFromSliceLeaky(Issued, arena, answer, .{});

    // Larger than one piece: the plugin never held it whole.
    try std.testing.expect(issued.size > made.part_bytes_max);

    var system = scenario.ctx(.system);
    const row = (try store.media.get(system.db, arena, issued.file)).?;

    try std.testing.expect(row.private);
    try std.testing.expectEqualStrings("application/pdf", row.mime_type);
    try std.testing.expectEqual(@as(i64, @intCast(issued.size)), row.size);

    const bytes = try files.read(arena, .files, row.storage_key, files_module.bytes_max);

    try std.testing.expect(std.mem.startsWith(u8, bytes, "%PDF-1.4\n% Invoice FK-1\n"));
    try std.testing.expect(std.mem.endsWith(u8, bytes, "%%EOF\n"));

    // The link it signed opens the file, as the plugin; another plugin reads none of it.
    const token = issued.link["/_links/".len..];
    const claims = (try link.verified(&system, token)).?;

    try std.testing.expectEqualStrings("invoicer.download", claims.intent);

    var as_invoicer = scenario.ctx(.system);

    as_invoicer.plugin = "invoicer";

    const opened = try registry.SDK.dispatch(&as_invoicer, made.Made, .{
        .id = claims.subject,
    });

    try std.testing.expectEqualStrings(row.storage_key, opened.key);

    var as_other = scenario.ctx(.system);

    as_other.plugin = "greeter";
    as_other.files = files;

    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&as_other, made.Made, .{
        .id = issued.file,
    }));

    // It attaches to an email the plugin sends without reading the site's media; another
    // plugin attaching it needs `media.read`.
    const messaging = @import("../../sdk/messaging.zig");
    const payload = try std.fmt.allocPrint(arena, "{{\"attachments\":[{{\"media\":\"{s}\"}}]}}", .{
        issued.file,
    });

    try std.testing.expect(messaging.carries_own_files_only(&system, "invoicer", payload));
    try std.testing.expect(!messaging.carries_own_files_only(&system, "greeter", payload));

    // Nor makes a file of invoicer's type, nor goes past its own file limit.
    _ = try registry.SDK.dispatch(&as_other, made.WritePart, .{
        .part = "stranger01",
        .data = "JVBERi0xLjQK",
    });
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&as_other, made.Make, .{
        .part = "stranger01",
        .filename = "stranger.pdf",
        .type = "invoicer.invoice",
    }));

    var past_limit = scenario.ctx(.system);

    past_limit.plugin = "invoicer";
    past_limit.files = files;

    try std.testing.expectError(error.Failed, registry.SDK.dispatch(&past_limit, made.WritePart, .{
        .part = "toolarge01",
        .offset = 64 << 20,
        .data = "JVBERi0xLjQK",
    }));
}

test "a part's name is the plugin's own word, and only a plugin writes one" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var nobody = harness.ctx(.system);

    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&nobody, made.WritePart, .{
        .part = "invoice0001",
        .data = "JVBERi0xLjQK",
    }));
}
