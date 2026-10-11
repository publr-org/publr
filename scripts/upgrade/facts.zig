//! What a fixture's seed made, said without reference to any schema, so a later release can
//! check every fact through its own doors: `facts.json` at the root of a fixture.

const std = @import("std");

pub const file_name = "facts.json";
pub const password = "fixture password, not secret";
const facts_bytes_max: u32 = 16 << 20;

pub const User = struct {
    email: []const u8,
    role: []const u8,
};
pub const Record = struct {
    type: []const u8,
    title: []const u8,
    status: []const u8,
};
pub const Term = struct {
    taxonomy: []const u8,
    title: []const u8,
};
pub const Media = struct {
    filename: []const u8,
};
pub const Secret = struct {
    name: []const u8,
};
/// A public address that answers 200 with `contains` in it.
pub const Page = struct {
    path: []const u8,
    contains: []const u8,
};

pub const Facts = struct {
    /// The releases that seeded it, oldest first: one for a fixture, every one for the
    /// lived site.
    releases: []const []const u8 = &.{},
    users: []const User = &.{},
    records: []const Record = &.{},
    terms: []const Term = &.{},
    media: []const Media = &.{},
    secrets: []const Secret = &.{},
    pages: []const Page = &.{},

    pub fn count(facts: Facts) u32 {
        std.debug.assert(facts.users.len <= std.math.maxInt(u32));

        const total = facts.users.len + facts.records.len + facts.terms.len +
            facts.media.len + facts.secrets.len + facts.pages.len;

        return @intCast(total);
    }

    /// `facts` with `more` after it: the lived site's history.
    pub fn append(arena: std.mem.Allocator, facts: Facts, more: Facts) !Facts {
        std.debug.assert(more.releases.len > 0);

        return .{
            .releases = try std.mem.concat(arena, []const u8, &.{ facts.releases, more.releases }),
            .users = try std.mem.concat(arena, User, &.{ facts.users, more.users }),
            .records = try std.mem.concat(arena, Record, &.{ facts.records, more.records }),
            .terms = try std.mem.concat(arena, Term, &.{ facts.terms, more.terms }),
            .media = try std.mem.concat(arena, Media, &.{ facts.media, more.media }),
            .secrets = try std.mem.concat(arena, Secret, &.{ facts.secrets, more.secrets }),
            .pages = try std.mem.concat(arena, Page, &.{ facts.pages, more.pages }),
        };
    }
};

pub fn read(io: std.Io, arena: std.mem.Allocator, site_dir: []const u8) !Facts {
    std.debug.assert(site_dir.len > 0);

    const path = try std.fs.path.join(arena, &.{ site_dir, file_name });
    const limit: std.Io.Limit = .limited(facts_bytes_max);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, arena, limit) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };

    return std.json.parseFromSliceLeaky(Facts, arena, text, .{
        .ignore_unknown_fields = true,
    });
}

pub fn write(io: std.Io, arena: std.mem.Allocator, site_dir: []const u8, facts: Facts) !void {
    std.debug.assert(site_dir.len > 0);
    std.debug.assert(facts.releases.len > 0);

    const text = try std.json.Stringify.valueAlloc(arena, facts, .{
        .whitespace = .indent_2,
    });

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = try std.fs.path.join(arena, &.{ site_dir, file_name }),
        .data = text,
    });
}
