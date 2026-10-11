//! Messages two or more translations of one language render differently: what Site Health
//! lists so a person can pick the one they want. Each candidate once per distinct text.
const std = @import("std");
const po = @import("po.zig");
const catalog_module = @import("catalog.zig");

const Source = catalog_module.Source;

pub const Candidate = struct {
    provider: []const u8,
    first_party: bool,
    /// The translation, or its plural forms one after another.
    forms: []const []const u8,
};

pub const Conflict = struct {
    context: []const u8,
    id: []const u8,
    candidates: []const Candidate,
};

pub const conflicts_max: u32 = 65_536;

/// Every message the sources translate in more than one way, in the order first met.
pub fn of(arena: std.mem.Allocator, sources: []const Source) po.Error![]const Conflict {
    std.debug.assert(sources.len <= 1024);

    var keys: std.StringArrayHashMapUnmanaged(std.ArrayList(Candidate)) = .empty;
    var ids: std.StringArrayHashMapUnmanaged([2][]const u8) = .empty;

    for (sources) |source| {
        const file = try po.parse(arena, source.po);

        for (file.messages) |message| {
            const key = std.mem.concat(arena, u8, &.{ message.context, "\x04", message.id }) catch {
                return error.OutOfMemory;
            };
            const entry = keys.getOrPut(arena, key) catch return error.OutOfMemory;

            if (!entry.found_existing) {
                entry.value_ptr.* = .empty;
                const pair = .{ message.context, message.id };

                ids.put(arena, key, pair) catch return error.OutOfMemory;
            }

            if (!holds(entry.value_ptr.items, message.forms)) {
                entry.value_ptr.append(arena, .{
                    .provider = source.provider,
                    .first_party = source.first_party,
                    .forms = message.forms,
                }) catch return error.OutOfMemory;
            }
        }
    }

    var out: std.ArrayList(Conflict) = .empty;

    for (keys.keys(), keys.values()) |key, candidates| {
        if (candidates.items.len < 2 or out.items.len == conflicts_max) {
            continue;
        }

        const pair = ids.get(key).?;

        out.append(arena, .{
            .context = pair[0],
            .id = pair[1],
            .candidates = candidates.items,
        }) catch return error.OutOfMemory;
    }

    return out.items;
}

fn holds(candidates: []const Candidate, forms: []const []const u8) bool {
    std.debug.assert(forms.len > 0);

    for (candidates) |candidate| {
        if (same(candidate.forms, forms)) {
            return true;
        }
    }

    return false;
}

fn same(left: []const []const u8, right: []const []const u8) bool {
    std.debug.assert(right.len > 0);

    if (left.len != right.len) {
        return false;
    }

    for (left, right) |one, other| {
        if (!std.mem.eql(u8, one, other)) {
            return false;
        }
    }

    return true;
}

test "a message translated two ways is a conflict; the same way twice is not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try of(arena, &.{
        .{
            .provider = "language_pl",
            .first_party = true,
            .po = "msgid \"Save\"\nmsgstr \"Zapisz\"\n" ++
                "msgid \"Trash\"\nmsgstr \"Kosz\"\n",
        },
        .{
            .provider = "pl_extra",
            .po = "msgid \"Save\"\nmsgstr \"Zachowaj\"\n" ++
                "msgid \"Trash\"\nmsgstr \"Kosz\"\n",
        },
        .{
            .provider = "pl_third",
            .po = "msgid \"Save\"\nmsgstr \"Zachowaj\"\n",
        },
    });

    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Save", found[0].id);
    try std.testing.expectEqual(@as(usize, 2), found[0].candidates.len);
    try std.testing.expect(found[0].candidates[0].first_party);
}
