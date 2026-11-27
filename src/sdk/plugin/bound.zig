//! A plugin as core reads it: `Bind` pairs its `define` with the words of its doc comments,
//! and `has`/`get` read its options, a list in the shape core keeps (`bound/declared.zig`).
//! The registration a plugin writes is `publr/plugin/define.zig`.
const std = @import("std");
const public = @import("../../publr/plugin/define.zig");
const declared = @import("bound/declared.zig");
const host_define = @import("../../publr/extend/host.zig");

pub const Manifest = public.Manifest;
pub const Described = public.Described;
pub const Definition = public.Definition;
pub const define = public.define;
pub const defined = public.defined;
pub const listed_in = public.listed_in;
pub const words = public.words;
pub const first = public.first;
pub const rest = public.rest;
pub const Words = public.Words;

const resolvers = declared.resolvers;
const extends = declared.extends;
const host_hooks = declared.host_hooks;

/// The plugin as every reader takes it: its manifest with the description from `main.zig`'s
/// `//!`, its options, and its words.
pub fn Bind(comptime Module: type, comptime Docs: type) type {
    comptime {
        if (!defined(Module)) {
            @compileError(@typeName(Module) ++ ": a plugin registers with " ++
                "`pub const plugin = publr.plugin.define(manifest, options)`");
        }

        const plugin = Module.plugin;
        _ = words(Docs, "main") orelse @compileError("plugin " ++
            plugin.manifest.name ++ ": main.zig needs a `//!` comment: its first line is the " ++
            "plugin's description, the rest the text on its settings page");
        const summary = Docs.first("main").?;

        if (summary.len == 0 or summary.len > summary_len_max) {
            @compileError("plugin " ++ plugin.manifest.name ++ ": the first line of main.zig's " ++
                "`//!` is the description, 1 to 200 characters");
        }

        if (plugin.manifest.version.len > version_len_max) {
            @compileError("plugin " ++ plugin.manifest.name ++ ": `version` is 1 to 32 chars");
        }

        check_options(plugin.manifest.name, @TypeOf(plugin.options));

        const Bound = struct {
            pub const manifest: Described = .{
                .name = plugin.manifest.name,
                .version = plugin.manifest.version,
                .summary = summary,
            };
            pub const options = plugin.options;
            // Null without `.extend`, and in the sandbox, which has none of the host's seams:
            // its build names `extend` as left out.
            pub const host = if (@hasField(@TypeOf(plugin.options), "extend") and
                @import("guest.zig").mode == .native)
                host_define.extended(plugin.manifest.name, plugin.options.extend)
            else
                null;
            pub const docs = Docs;
            pub const source = Module;
            pub const settings_text = Docs.rest("main").?;
        };

        @import("secret_define.zig").check(Bound);

        return Bound;
    }
}

const summary_len_max: u32 = 200;
const version_len_max: u32 = 32;

/// What `define` takes.
const options_known = [_][]const u8{
    "records",                 "operations",
    "hooks",                   "events",
    "permissions",             "secrets",
    "depends_on",              "compatible_with",
    "remotes",                 "field_kinds",
    "register_fields",         "roles",
    "translations",            "limits",
    "pages",                   "panels",
    "jobs",                    "menu",
    "icons",                   "register_statuses",
    "extend",                  "webhooks",
    "register_location_rules", "register_providers",
    "register_columns",        "dimensions",
    "taxonomies",              "register_taxonomies",
    "contracts",               "user_types",
    "request",                 "ledger",
};

/// What only a built-in plugin takes outside `.extend`, until each finds its place.
pub const options_built_in = [_][]const u8{
    "row_actions",
};

fn check_options(comptime plugin: []const u8, comptime Options: type) void {
    comptime {
        std.debug.assert(plugin.len > 0);

        const fields = std.meta.fieldNames(Options).len;
        const listed = options_known.len + options_built_in.len;

        // Each option's name against every known one, a byte at a time.
        @setEvalBranchQuota(1000 + fields * listed * 64);

        for (std.meta.fieldNames(Options)) |name| {
            if (!listed_in(&options_known, name) and !listed_in(&options_built_in, name)) {
                @compileError("plugin " ++ plugin ++ ": `define` has no option `." ++ name ++ "`");
            }
        }
    }
}

/// Whether the plugin has the option `name`: a field of `define`'s options, or what one of
/// them gives (`.records` content types, `.hooks` middleware, `.extend`'s seams).
pub fn has(comptime Plugin: type, comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    if (comptime host_define.seam(name)) {
        if (comptime !extends(Plugin)) {
            return false;
        }

        return comptime Plugin.host.has(name);
    }

    const Options = @TypeOf(Plugin.options);
    const listed_kind = std.mem.eql(u8, name, "content_types") or
        std.mem.eql(u8, name, "internal_records");
    const from_records = @hasField(Options, "records") and listed_kind;
    const hook_lists = @hasField(Options, "hooks") or @hasField(Options, "records") or
        comptime host_hooks(Plugin).len > 0;
    const from_hooks = hook_lists and std.mem.eql(u8, name, "middleware");
    const from_groups = @hasField(Options, "register_fields") and
        std.mem.eql(u8, name, "custom_fields");

    const from_words = std.mem.eql(u8, name, "namespaces");

    return @hasField(Options, name) or from_records or from_hooks or from_groups or
        from_words;
}

/// The option `name`; a list comes back as a slice either way, empty when the plugin has
/// none of it.
pub fn get(comptime Plugin: type, comptime name: []const u8) Got(Plugin, name) {
    if (comptime !has(Plugin, name)) {
        if (comptime !list_option(name)) {
            @compileError("plugin " ++ Plugin.manifest.name ++ " has no `" ++ name ++ "`");
        }

        return &.{};
    }

    if (comptime host_define.seam(name)) {
        return comptime Plugin.host.get(name);
    }

    inline for (resolvers) |entry| {
        if (comptime std.mem.eql(u8, entry[0], name)) {
            return comptime entry[2](Plugin);
        }
    }

    const value = @field(Plugin.options, name);

    return switch (@typeInfo(@TypeOf(value))) {
        .array => &value,
        .@"struct" => |shape| if (shape.is_tuple) &value else value,
        else => value,
    };
}

/// Whether `name` is a list read the same way whether or not a plugin gives it.
fn list_option(comptime name: []const u8) bool {
    std.debug.assert(name.len > 0);

    inline for (resolvers) |entry| {
        if (comptime std.mem.eql(u8, entry[0], name)) {
            return true;
        }
    }

    return host_define.listed(name);
}

pub fn Got(comptime Plugin: type, comptime name: []const u8) type {
    if (host_define.listed(name)) {
        return @FieldType(host_define.Host, name);
    }

    if (host_define.seam(name)) {
        return host_define.Host.Got(Plugin.host, name);
    }

    inline for (resolvers) |entry| {
        if (std.mem.eql(u8, entry[0], name)) {
            return []const entry[1];
        }
    }

    const Value = @TypeOf(@field(Plugin.options, name));

    return switch (@typeInfo(Value)) {
        .array => |array| []const array.child,
        .@"struct" => |shape| if (shape.is_tuple) *const Value else Value,
        else => Value,
    };
}

test "a plugin written with define, bound to its words" {
    const Docs = Words(.{
        .{ "main", "Asks visitors whether a page helped.\n\nThe answers show here." },
    });
    const Module = struct {
        pub const plugin = define(.{
            .name = "helpful",
            .version = "0.1.0",
        }, .{
            .compatible_with = [_][]const u8{"blog"},
        });
    };
    const Plugin = Bind(Module, Docs);

    const summary = Plugin.manifest.summary;

    try std.testing.expectEqualStrings("Asks visitors whether a page helped.", summary);
    try std.testing.expectEqualStrings("The answers show here.", Plugin.settings_text);
    try std.testing.expect(has(Plugin, "compatible_with"));
    try std.testing.expect(!has(Plugin, "operations"));
    try std.testing.expectEqualStrings("blog", get(Plugin, "compatible_with")[0]);
}
