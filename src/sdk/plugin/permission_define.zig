//! A plugin's requests as it writes them: a key and yes/no flags (`records.write` with
//! `.publish = true`, `http.fetch` with `.domains`). Each key is core's, and takes only the
//! options its entry names; anything else fails the build. Secrets are not among them
//! (`secret_define.zig`).
const std = @import("std");
const permission = @import("../../model/permission.zig");
const outside = @import("../../model/outside.zig");
const Ask = @import("../../model/sandboxed_plugin.zig").Ask;

pub const asks_max: u32 = 64;

const options_always = [_][]const u8{ "key", "reason" };

pub fn asks_of(comptime Plugin: type) []const Ask {
    comptime {
        const Options = @TypeOf(Plugin.options);
        var asks: []const Ask = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (@hasField(Options, "permissions")) {
            for (Plugin.options.permissions) |request| {
                asks = asks ++ asks_for(Plugin.manifest.name, request);
            }
        }

        if (asks.len > asks_max) {
            @compileError("plugin " ++ Plugin.manifest.name ++ ": more than 64 permissions");
        }

        const done = asks;

        return done;
    }
}

fn asks_for(comptime plugin: []const u8, comptime request: anytype) []const Ask {
    comptime {
        const Request = @TypeOf(request);

        std.debug.assert(plugin.len > 0);

        if (problem(request)) |text| {
            @compileError("plugin " ++ plugin ++ ": " ++ text);
        }

        // Calling another plugin's operation (`call:inventory.reserve`) is asked for as it is.
        const entry = permission.find(&permission.core, request.key) orelse
            return &[_]Ask{.{
                .key = request.key,
                .reason = request.reason,
            }};
        var ask: Ask = .{
            .key = request.key,
            .reason = request.reason,
        };

        if (@hasField(Request, "records")) {
            ask.records = request.records;
        }

        if (@hasField(Request, "taxonomies")) {
            ask.taxonomies = request.taxonomies;
        }

        if (@hasField(Request, "domains")) {
            ask.domains = request.domains;
        }

        for (entry.flags) |flag| {
            if (@hasField(Request, @tagName(flag))) {
                @field(ask, @tagName(flag)) = @field(request, @tagName(flag));
            }
        }

        const done = ask;

        return &[_]Ask{done};
    }
}

/// What is wrong with one request, if anything: no reason, a key core does not have, an
/// option its key does not take.
fn problem(comptime request: anytype) ?[]const u8 {
    comptime {
        const Request = @TypeOf(request);
        const key = request.key;

        std.debug.assert(key.len > 0);

        if (!@hasField(Request, "reason") or request.reason.len == 0) {
            return "permission " ++ key ++ " needs a `.reason`";
        }

        const call = std.mem.startsWith(u8, key, "call:");
        const entry = permission.find(&permission.core, key);

        if (!call and entry == null) {
            return "no permission `" ++ key ++ "`";
        }

        for (std.meta.fieldNames(Request)) |option| {
            const taken = if (entry) |found| takes(found, option) else listed(
                &options_always,
                option,
            );

            if (!taken and set(request, option)) {
                return "permission " ++ key ++ " takes no `." ++ option ++ "`";
            }
        }

        if (@hasField(Request, "domains")) {
            return domains_problem(request.domains);
        }

        return null;
    }
}

/// What is wrong with `http.fetch`'s domains, if anything: each exact, `*.example.com` or
/// `*`, at most 32.
fn domains_problem(comptime domains: []const []const u8) ?[]const u8 {
    comptime {
        // Each domain is read a character at a time, a few times over.
        @setEvalBranchQuota(1000 + domains.len * outside.domain_len_max * 8);

        if (domains.len > outside.domains_max) {
            return "http.fetch lists more than 32 domains";
        }

        std.debug.assert(domains.len <= outside.domains_max);

        for (domains) |domain| {
            if (!outside.valid_domain(domain)) {
                return "http.fetch's domain `" ++ domain ++ "` is none of: a host name " ++
                    "(api.example.com), a wildcard (*.example.com), or *";
            }
        }

        return null;
    }
}

/// Whether a request says something with `option`: an option no key takes always does; a
/// flag when true, a list when it names something (a typed request carries every option).
fn set(comptime request: anytype, comptime option: []const u8) bool {
    comptime {
        std.debug.assert(option.len > 0);

        if (!listed(&options_known, option)) {
            return true;
        }

        const value = @field(request, option);

        return switch (@typeInfo(@TypeOf(value))) {
            .bool => value,
            else => value.len > 0,
        };
    }
}

const options_known = [_][]const u8{
    "key",    "reason",  "records",  "taxonomies", "domains",
    "drafts", "private", "internal", "publish",
};

/// Whether the key `entry` takes the option `option`: its narrowing, its flags, and the
/// key and reason every request has.
fn takes(comptime entry: *const permission.Permission, comptime option: []const u8) bool {
    comptime {
        std.debug.assert(option.len > 0);

        if (listed(&options_always, option)) {
            return true;
        }

        if (entry.narrowing != .none and std.mem.eql(u8, option, @tagName(entry.narrowing))) {
            return true;
        }

        for (entry.flags) |flag| {
            if (std.mem.eql(u8, option, @tagName(flag))) {
                return true;
            }
        }

        return false;
    }
}

/// What a plugin was given for one request: whether the key is on, and its flags as
/// granted now.
pub const Grant = struct {
    on: bool,
    drafts: bool = false,
    private: bool = false,
    internal: bool = false,
    publish: bool = false,
    /// `http.fetch`'s domains as granted now: compiled in, as asked; installed, the list an
    /// administrator left (as asked until one is saved).
    domains: []const []const u8 = &.{},

    pub const off: Grant = .{
        .on = false,
    };

    /// Read from what the plugin holds for the key; null when it holds nothing.
    pub fn of(comptime key: []const u8, held: ?permission.Held) Grant {
        comptime {
            if (permission.find(&permission.core, key) == null) {
                @compileError("no permission `" ++ key ++ "`");
            }
        }

        const found = held orelse return off;

        std.debug.assert(std.mem.eql(u8, found.key, key));

        return .{
            .on = true,
            .drafts = found.drafts,
            .private = found.private,
            .internal = found.internal,
            .publish = found.publish,
            .domains = found.domains,
        };
    }

    /// As the sandbox carries it: the key on in the first bit, a flag a bit each after it.
    pub fn bits(grant: Grant) u32 {
        std.debug.assert(grant.on or !(grant.drafts or grant.publish));

        if (!grant.on) {
            return 0;
        }

        const flags = [_]bool{ grant.drafts, grant.private, grant.internal, grant.publish };
        var packed_bits: u32 = 1;

        for (flags, 1..) |flag, shift| {
            packed_bits |= @as(u32, @intFromBool(flag)) << @intCast(shift);
        }

        return packed_bits;
    }

    pub fn from_bits(packed_bits: u32) Grant {
        std.debug.assert(packed_bits < 1 << 5);

        const on = packed_bits & 1 == 1;

        return .{
            .on = on,
            .drafts = on and packed_bits & 2 != 0,
            .private = on and packed_bits & 4 != 0,
            .internal = on and packed_bits & 8 != 0,
            .publish = on and packed_bits & 16 != 0,
        };
    }
};

fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) {
            return true;
        }
    }

    return false;
}

test "a request is checked against its key: known keys, the options each takes, a reason" {
    comptime {
        std.debug.assert(problem(.{
            .key = "records.write",
            .records = &[_][]const u8{"post"},
            .publish = true,
            .reason = "Puts prices live",
        }) == null);
        std.debug.assert(problem(.{
            .key = "http.fetch",
            .domains = &[_][]const u8{"api.supplier.com"},
            .reason = "Downloads prices",
        }) == null);
        std.debug.assert(problem(.{
            .key = "call:cart.view",
            .reason = "Shows the cart",
        }) == null);
        std.debug.assert(problem(.{
            .key = "content.write",
            .reason = "An old key",
        }) != null);
        // A secret is declared in `.secrets`, never asked for as a permission.
        std.debug.assert(problem(.{
            .key = "secret.SUPPLIER_API_KEY",
            .reason = "Signs requests",
        }) != null);
        std.debug.assert(problem(.{
            .key = "records.read",
            .domains = &[_][]const u8{"example.com"},
            .reason = "Domains on a read",
        }) != null);
        std.debug.assert(problem(.{
            .key = "http.fetch",
            .domains = &[_][]const u8{ "*", "*.supplier-cdn.com" },
            .reason = "Reads pages",
        }) == null);
        std.debug.assert(problem(.{
            .key = "http.fetch",
            .domains = &[_][]const u8{"https://api.supplier.com"},
            .reason = "A URL, not a domain",
        }) != null);
        std.debug.assert(problem(.{
            .key = "http.fetch",
            .domains = &[_][]const u8{"*.com"},
            .reason = "A whole top-level domain",
        }) != null);
        std.debug.assert(problem(.{
            .key = "records.read",
            .publish = true,
            .reason = "A write's flag",
        }) != null);
        std.debug.assert(problem(.{
            .key = "users.read",
            .private = true,
            .reason = "A flag the key lacks",
        }) != null);
        std.debug.assert(problem(.{
            .key = "media.write",
        }) != null);
        std.debug.assert(problem(Ask{
            .key = "users.names",
            .reason = "A typed request carries every option, unset",
        }) == null);
    }

    const asked = comptime asks_for("shop", .{
        .key = "records.read",
        .records = &[_][]const u8{"post"},
        .drafts = true,
        .reason = "Reads posts",
    });

    try std.testing.expectEqual(@as(usize, 1), asked.len);
    try std.testing.expect(asked[0].drafts and !asked[0].private);
    try std.testing.expectEqualStrings("post", asked[0].records[0]);
}

test "a grant crosses the sandbox as bits and back" {
    const granted: Grant = .{
        .on = true,
        .drafts = true,
        .publish = true,
    };
    const back = Grant.from_bits(granted.bits());

    try std.testing.expect(back.on and back.drafts and back.publish);
    try std.testing.expect(!back.private and !back.internal);
    try std.testing.expect(!Grant.from_bits(Grant.off.bits()).on);
    try std.testing.expect(Grant.of("records.read", null).on == false);
    try std.testing.expect(Grant.of("records.write", .{
        .key = "records.write",
        .publish = true,
    }).publish);
}
