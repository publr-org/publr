//! What the plugin operations answer: a plugin as the list shows it, and with everything
//! its page shows. Their documented examples live here too, each as the parity world
//! leaves it: `greeter` enabled, rolled back from 0.2.0, with 0.2.0 offered again; `farewell`
//! added and disabled.
const std = @import("std");
const permission = @import("../../model/permission.zig");

/// How a plugin is loaded: `native`, built into this binary, or `sandboxed`, installed and run
/// in the sandbox.
pub const Mode = @import("../../model/plugin.zig").Mode;

/// One request as the install page and the plugin's page show it.
pub const Request = struct {
    key: []const u8,
    sentence: []const u8,
    reason: []const u8,
    /// Its risk with the flags on now.
    tier: permission.Tier,
    state: State,
    /// The content types or taxonomies it names; empty for every one.
    names: []const []const u8 = &.{},
    /// `http.fetch`'s domains as set now: exact, `*.example.com`, or `*` (anywhere public).
    domains: []const []const u8 = &.{},
    /// On an update's review: the domains the new version adds, joining the list on Allow.
    new_domains: []const []const u8 = &.{},
    /// Each flag it asked for, and whether it is on now.
    flags: []const Flag = &.{},

    pub const State = enum { granted, pending, denied, unavailable };

    pub const Flag = struct {
        name: permission.Flag,
        on: bool,
    };
};

/// A plugin as the list shows it, built-in or installed.
pub const Summary = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    mode: Mode,
    /// Always, for a native plugin.
    enabled: bool,
    /// How many requests wait for an administrator.
    pending: u32,
    /// The version of a newer module waiting to be applied.
    update: ?[]const u8,
};

/// A plugin with everything its page shows.
pub const Detail = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    /// `native` for a built-in plugin: always enabled, every request granted, nothing to
    /// review, update, roll back or remove.
    mode: Mode = .sandboxed,
    hash: []const u8,
    enabled: bool,
    /// Every request and where it stands; for a plugin disabled, where enabling it
    /// would leave it.
    requests: []const Request,
    operations: []const []const u8,
    /// A newer version waiting, and where its requests would stand once applied.
    update: ?Next = null,
    /// The version the last update replaced, to roll back to.
    previous: ?[]const u8 = null,
    /// What the plugin brings that its sandboxed build left out, each with why.
    left_out: []const []const u8 = &.{},
    /// What the plugin checks warned of, each `file:line: why`: never a stop.
    warnings: []const []const u8 = &.{},
    /// Why it can't be enabled: each remote it needs (`depends_on`) that does not fit what
    /// is there now, in plain words.
    blocked: []const []const u8 = &.{},
    /// Each remote it works with (`compatible_with`) that is off, and why: calls to it
    /// answer `Unavailable` and its hooks don't run until it fits.
    off: []const Off = &.{},
    /// The secrets it declares: shown under its `http.fetch` request, never their values.
    secrets: []const Secret = &.{},

    /// A secret the plugin declares, and whether it has a value; never the value.
    pub const Secret = struct {
        name: []const u8,
        label: []const u8,
        /// Where to find it, as the plugin says.
        help: []const u8 = "",
        set: bool = false,
        /// The other plugins that declare the same name and so share its value.
        shared_with: []const []const u8 = &.{},
    };

    pub const Next = struct {
        version: []const u8,
        requests: []const Request,
        /// The enabled plugins that need this plugin as it is now, each with why: applying
        /// the update is refused until they are updated or removed.
        stops: []const []const u8 = &.{},
        /// The remotes of other plugins it would switch off, each with why.
        switches_off: []const []const u8 = &.{},
    };
};

const example_hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

pub const example_request: Request = .{
    .key = "users.names",
    .sentence = "See the names of people on your site",
    .reason = "Greets the people on the site by name",
    .tier = .low,
    .state = .granted,
};

const example_next: Detail.Next = .{
    .version = "0.2.0",
    .requests = &.{.{
        .key = "users.read",
        .sentence = "Access user accounts and email addresses",
        .reason = "Greets people by their email address too",
        .tier = .high,
        .state = .granted,
    }},
};

/// `greeter` as it runs: enabled, 0.2.0 offered, 0.2.0 behind it to roll back to.
pub const example_detail: Detail = .{
    .name = "greeter",
    .version = "0.1.0",
    .summary = "Greetings kept as records",
    .hash = example_hash,
    .enabled = true,
    .requests = &.{example_request},
    .operations = &.{ "greeter.greet", "greeter.count", "greeter.people" },
    .update = example_next,
    .previous = "0.2.0",
    .off = &.{.{
        .name = "sampler.hello",
        .why = "sampler isn't installed or enabled",
    }},
};

const no_update: ?Detail.Next = null;

pub const example_updated: Detail = with(.{
    .version = "0.2.0",
    .update = no_update,
    .previous = "0.1.0",
    .off = &.{},
});
pub const example_cancelled: Detail = with(.{
    .update = no_update,
});
pub const example_rolled_back: Detail = with(.{
    .version = "0.2.0",
    .previous = "0.1.0",
    .off = &.{},
});
pub const example_disabled: Detail = with(.{
    .enabled = false,
});

pub const example_enabled: Detail = .{
    .name = "farewell",
    .version = "0.1.0",
    .summary = "Says goodbye",
    .hash = example_hash,
    .enabled = true,
    .requests = &.{},
    .operations = &.{"farewell.say"},
};

const Changes = struct {
    version: ?[]const u8 = null,
    enabled: ?bool = null,
    update: ??Detail.Next = null,
    previous: ??[]const u8 = null,
    off: ?[]const Off = null,
};

fn with(changes: Changes) Detail {
    std.debug.assert(example_detail.name.len > 0);
    std.debug.assert(example_detail.enabled);

    var detail = example_detail;

    if (changes.version) |version| {
        detail.version = version;
    }

    if (changes.enabled) |enabled| {
        detail.enabled = enabled;
    }

    if (changes.update) |update| {
        detail.update = update;
    }

    if (changes.previous) |previous| {
        detail.previous = previous;
    }

    if (changes.off) |off| {
        detail.off = off;
    }

    return detail;
}

/// A remote switched off, and why, in plain words.
pub const Off = struct {
    name: []const u8,
    why: []const u8,
};
