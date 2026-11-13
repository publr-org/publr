//! What `publr cloud deploy` takes when it is not told: the account's space when it has one
//! (several are listed for the person to choose), and an address made from the folder's name
//! with a random ending, as Cloud makes a new project's, so it is never taken.
const std = @import("std");
const report = @import("../../lib/report.zig");

const ending_len: u32 = 6;
const slug_len_max: u32 = 63;
const slug_len_min: u32 = 3;
const spaces_max: u32 = 64;

/// The space to deploy into; null, having said why, when the account has none or several.
pub fn space(
    io: std.Io,
    arena: std.mem.Allocator,
    dashboard: []const u8,
    token: []const u8,
) !?[]const u8 {
    std.debug.assert(token.len > 0);
    std.debug.assert(dashboard.len > 0);

    const reply = try @import("../remote.zig").post(io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}/api/cloud.spaces", .{dashboard}),
        .payload = "{}",
        .token = token,
    });

    if (reply.status == .unauthorized) {
        report.err("publr cloud deploy: {s} no longer takes this sign-in; run " ++
            "`publr cloud login` again", .{dashboard});
        return null;
    }

    if (reply.status != .ok) {
        report.err("publr cloud deploy: {s} answered {d} when asked your spaces", .{
            dashboard,
            @intFromEnum(reply.status),
        });
        return null;
    }

    const Listing = struct {
        spaces: []const struct {
            slug: []const u8,
            name: []const u8 = "",
        } = &.{},
    };
    const listing = try std.json.parseFromSliceLeaky(Listing, arena, reply.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    if (listing.spaces.len == 1) {
        return listing.spaces[0].slug;
    }

    if (listing.spaces.len == 0) {
        report.err("publr cloud deploy: your account has no space yet; make one at {s}", .{
            dashboard,
        });
        return null;
    }

    report.err("publr cloud deploy: your account has several spaces; say which with --space:", .{});

    for (listing.spaces[0..@min(listing.spaces.len, spaces_max)]) |found| {
        report.err("  {s}  ({s})", .{ found.slug, found.name });
    }

    return null;
}

/// `<the folder's name>-<six random letters and digits>`: the name lowercased, anything not
/// a-z or 0-9 a single hyphen, cut to leave room for the ending; `site` when nothing is left.
pub fn slug(io: std.Io, arena: std.mem.Allocator, folder_name: []const u8) ![]const u8 {
    std.debug.assert(ending_len > 0);

    var ending_bytes: [ending_len]u8 = undefined;

    io.random(&ending_bytes);

    return slug_with(arena, folder_name, &ending_bytes);
}

fn slug_with(arena: std.mem.Allocator, folder_name: []const u8, random: []const u8) ![]const u8 {
    std.debug.assert(random.len == ending_len);

    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    const room = slug_len_max - ending_len - 1;
    var made: std.ArrayList(u8) = .empty;

    for (folder_name) |char| {
        if (made.items.len == room) {
            break;
        }

        if (std.ascii.isAlphanumeric(char)) {
            try made.append(arena, std.ascii.toLower(char));
        } else if (made.items.len > 0 and made.items[made.items.len - 1] != '-') {
            try made.append(arena, '-');
        }
    }

    const base = std.mem.trimEnd(u8, made.items, "-");
    var ending: [ending_len]u8 = undefined;

    for (random, &ending) |byte, *char| {
        char.* = alphabet[byte % alphabet.len];
    }

    const named = if (base.len > 0) base else "site";
    const result = try std.fmt.allocPrint(arena, "{s}-{s}", .{ named, &ending });

    std.debug.assert(result.len >= slug_len_min and result.len <= slug_len_max);

    return result;
}

test "an address from the folder's name, never taken" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    const random = [_]u8{ 0, 1, 2, 26, 27, 35 };

    try std.testing.expectEqualStrings("my-shop-abc019", try slug_with(arena, "My Shop!", &random));
    try std.testing.expectEqualStrings("site-abc019", try slug_with(arena, "...", &random));
    try std.testing.expectEqualStrings("a-b-abc019", try slug_with(arena, "a__b", &random));

    const long = "x" ** 100;

    try std.testing.expectEqual(@as(usize, 63), (try slug_with(arena, long, &random)).len);
}
