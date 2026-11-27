//! What an installed plugin asks of its ctx beside its calls, on the sampler's `tip`: a
//! refusal's words (`failure_message`), whether a call would be let in (`may`), and calls
//! made as the plugin alone (`as_plugin`), each the answer a compiled-in build gives.
const std = @import("std");
const scenarios = @import("scenarios.zig");
const scenarios_remotes = @import("scenarios_remotes.zig");

const Scenario = scenarios.Scenario;
const admin = scenarios.admin;

test "an installed plugin reads a refusal's words, asks what it may call, calls alone" {
    var scenario: Scenario = undefined;
    try scenario.init();
    defer scenario.deinit();

    const module = @embedFile("sandboxed_plugin_sampler");

    _ = try scenarios_remotes.put(&scenario, "sampler.wasm", module);
    try scenarios_remotes.enable(&scenario, "sampler");

    const tipped = try scenario.call(admin, "sampler.tip", "{\"id\":\"t1\",\"points\":5}");
    const Tipped = struct {
        posted: i64,
        refused: []const u8,
        said: []const u8,
        may_greet: bool,
        may_list_users: bool,
        alone_posted: i64,
        alone_signed_in: bool,
    };
    var memory = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memory.deinit();

    const read = try std.json.parseFromSliceLeaky(Tipped, memory.allocator(), tipped, .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expectEqualStrings("Overdrawn", read.refused);
    try std.testing.expectEqualStrings("This would break an account's limit", read.said);
    try std.testing.expect(read.may_greet);
    try std.testing.expect(!read.may_list_users);
    try std.testing.expectEqual(read.posted, read.alone_posted);
    try std.testing.expect(!read.alone_signed_in);
}
