//! A plugin's page in the admin: what each of its providers answered at install (a contract
//! part named `.at_install`, `orders.item`'s `declare`), as core keeps it, read only. The
//! answers change only when the plugin updates.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const answers_operations = @import("../../operations/provider/answers.zig");
const Registered = @import("../../model/provider.zig").Registered;

const Session = admin.Session;
const Error = admin.Error;
const Item = admin.views.Plugin.AnswersItem;
const Line = std.meta.Child(@FieldType(Item, "lines"));

/// The most answers one provider's are listed by, top-level names.
const lines_max: u32 = 64;

/// Each provider of `plugin` asked something at install, with what it answered.
pub fn of(session: *Session, plugin: []const u8) Error![]const Item {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(session.signed_in());

    var items: std.ArrayList(Item) = .empty;

    for (registry.providers) |provider| {
        try add(session, plugin, provider, &items);
    }

    if (session.ctx.sandboxed_plugins) |sandboxed| {
        for (sandboxed.manifests()) |manifest| {
            for (manifest.providers) |provider| {
                var owned = provider;

                owned.plugin = manifest.name;
                try add(session, plugin, owned, &items);
            }
        }
    }

    return items.items;
}

fn add(
    session: *Session,
    plugin: []const u8,
    provider: Registered,
    items: *std.ArrayList(Item),
) Error!void {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(provider.name.len > 0);

    if (provider.at_install.len == 0 or !std.mem.eql(u8, provider.plugin, plugin)) {
        return;
    }

    var reading = session.*;
    const kept = registry.SDK.dispatch(&reading.ctx, answers_operations.Answers, .{
        .contract = provider.contract,
        .provider = provider.name,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };

    try items.append(session.arena, .{
        .contract = provider.contract,
        .provider = if (provider.label.len > 0)
            try session.declared(provider.label)
        else
            provider.name,
        .version = kept.version,
        .lines = try lines_of(session.arena, kept.answers.text),
    });
}

/// The answer's top-level names, each with its value as text.
fn lines_of(arena: std.mem.Allocator, text: []const u8) Error![]const Line {
    std.debug.assert(text.len <= 1 << 20);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return &.{};
    };

    if (parsed != .object) {
        return &.{};
    }

    var lines: std.ArrayList(Line) = .empty;
    var fields = parsed.object.iterator();

    while (fields.next()) |field| {
        if (lines.items.len == lines_max) {
            break;
        }

        const value = field.value_ptr.*;
        const shown = if (value == .string)
            value.string
        else
            try std.json.Stringify.valueAlloc(arena, value, .{});

        try lines.append(arena, .{
            .name = field.key_ptr.*,
            .value = shown,
        });
    }

    return lines.items;
}

test "an answer's names and values, as text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const lines = try lines_of(arena_state.allocator(), "{\"supply\":\"goods\",\"rate\":23}");

    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("goods", lines[0].value);
    try std.testing.expectEqualStrings("23", lines[1].value);
    try std.testing.expectEqual(@as(usize, 0), (try lines_of(arena_state.allocator(), "[1]")).len);
}
