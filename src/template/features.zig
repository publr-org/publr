//! What an app's templates may use of Publr, in one list: the `Publr.build.*` and
//! `Publr.request.*` functions, the page's words (`Publr.t`), the directives, a component
//! tag's attributes, and the settings in `app.zon` and `addresses.zon`. The compiler refuses
//! a function the list lacks and warns of one on its way out; `plugin surface` offers each
//! as `template:<name>`, so a release that loses one says so (`BREAKING.md`).
const std = @import("std");
const Deprecated = @import("../sdk/operation.zig").Deprecated;
const app = @import("../model/app.zig");
const addresses = @import("../model/app/addresses.zig");

pub const Kind = enum { function, words, directive, attribute, setting };

pub const Feature = struct {
    name: []const u8,
    kind: Kind,
    deprecated: ?Deprecated = null,
};

/// The functions a template calls on `Publr.build` (when the site is built) or
/// `Publr.request` (on each request), by name: `getCollection`, not `getCollection(…)`.
pub const functions = [_]Feature{
    function("getEntry"),     function("getCollection"), function("getReferences"),
    function("getReference"), function("get"),           function("findOne"),
    function("find"),         function("query"),         function("media"),
    function("mediaUrl"),     function("money"),         function("now"),
    function("locale"),       function("languages"),     function("managed"),
    function("base"),         function("baseUrl"),       function("session"),
    function("header"),       function("cookie"),        function("param"),
    function("random"),       function("userField"),     function("call"),
    function("redirect"),
};

/// Everything else a template or an app's folder names, each read from where it is handled,
/// so nothing is listed twice: the page's words (`expression.zig`), the directives
/// (`markup.zig`, `json_script.zig`), a component tag's attributes (`components.zig`) and the
/// fields of the structs `app.zon` and `addresses.zon` are read into.
pub const others = named("Publr.", &@import("expression.zig").words_functions, .words) ++
    named("", &directives, .directive) ++
    named("", &@import("components.zig").publr_attributes, .attribute) ++
    settings(app.Config, "app.zon.") ++ settings(addresses.Entry, "addresses.zon.");

const directives = @import("markup.zig").directives ++ .{@import("json_script.zig").directive};

/// Each of `names` as a feature of `kind`, `prefix` in front.
fn named(
    comptime prefix: []const u8,
    comptime names: []const []const u8,
    comptime kind: Kind,
) [names.len]Feature {
    comptime {
        std.debug.assert(names.len > 0);

        var listed: [names.len]Feature = undefined;

        for (names, &listed) |name, *feature| {
            feature.* = other(prefix ++ name, kind);
        }

        return listed;
    }
}

fn function(comptime name: []const u8) Feature {
    return .{
        .name = name,
        .kind = .function,
    };
}

fn other(comptime name: []const u8, comptime kind: Kind) Feature {
    return .{
        .name = name,
        .kind = kind,
    };
}

/// Each field of `Settings` as a setting: `app.zon.mount`.
fn settings(comptime Settings: type, comptime prefix: []const u8) [fields_of(Settings)]Feature {
    comptime {
        std.debug.assert(prefix.len > 0);

        const fields = std.meta.fieldNames(Settings);
        var listed: [fields.len]Feature = undefined;

        for (fields, &listed) |field, *feature| {
            feature.* = other(prefix ++ field, .setting);
        }

        return listed;
    }
}

fn fields_of(comptime Settings: type) u32 {
    return @intCast(std.meta.fieldNames(Settings).len);
}

/// The function called `name` (`getCollection`), when templates have one.
pub fn function_named(name: []const u8) ?Feature {
    std.debug.assert(name.len > 0);

    for (functions) |feature| {
        if (std.mem.eql(u8, feature.name, name)) {
            return feature;
        }
    }

    return null;
}

/// Every feature as `plugin surface` offers it: `template:Publr.build.getCollection`,
/// `template:Publr.request.getCollection`, `template:set:markdown`, `template:app.zon.mount`.
pub const offered = listed: {
    var names: [functions.len * 2 + others.len][]const u8 = undefined;
    var index: usize = 0;

    for (functions) |feature| {
        names[index] = "template:Publr.build." ++ feature.name;
        names[index + 1] = "template:Publr.request." ++ feature.name;
        index += 2;
    }

    for (others) |feature| {
        names[index] = "template:" ++ feature.name;
        index += 1;
    }

    const final = names;

    break :listed final;
};

/// Every feature on its way out, with its name as `offered` writes it after `template:`.
pub const Retiring = struct {
    name: []const u8,
    deprecated: Deprecated,
};

pub const deprecated = listed: {
    var count: usize = 0;

    for (functions ++ others) |feature| {
        if (feature.deprecated != null) {
            count += 1;
        }
    }

    var list: [count]Retiring = undefined;
    var index: usize = 0;

    for (functions ++ others) |feature| {
        const found = feature.deprecated orelse continue;
        const scope = if (feature.kind == .function) "Publr.*." else "";

        @import("../sdk/operation.zig").check_deprecated(feature.name, found);
        list[index] = .{
            .name = scope ++ feature.name,
            .deprecated = found,
        };
        index += 1;
    }

    const final = list;

    break :listed final;
};

test "every function the JavaScript runtime offers a template is in the list" {
    const runtime = @embedFile("javascript/runtime.js");
    const start = std.mem.indexOf(u8, runtime, "const api = scope => Object.freeze({").?;
    const end = std.mem.indexOfPos(u8, runtime, start, "\n  });").?;
    var lines = std.mem.splitScalar(u8, runtime[start..end], '\n');
    var seen: u32 = 0;

    _ = lines.next();

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " ");

        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "//") or
            std.mem.startsWith(u8, trimmed, "const ") or std.mem.startsWith(u8, trimmed, "if ") or
            std.mem.startsWith(u8, trimmed, "return ") or std.mem.startsWith(u8, trimmed, "."))
        {
            continue;
        }

        const after_get = if (std.mem.startsWith(u8, trimmed, "get ")) trimmed[4..] else trimmed;
        const name_end = std.mem.indexOfAny(u8, after_get, ":(") orelse continue;
        const name = after_get[0..name_end];

        if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) {
            continue;
        }

        if (function_named(name) == null) {
            std.debug.print("runtime.js offers templates `{s}`, which features.zig lacks\n", .{
                name,
            });
            return error.TestUnexpectedResult;
        }

        seen += 1;
    }

    try std.testing.expect(seen >= 20);
}

test "settings come from the structs app.zon and addresses.zon are read into" {
    var found_mount = false;

    for (offered) |name| {
        if (std.mem.eql(u8, name, "template:app.zon.mount")) {
            found_mount = true;
        }
    }

    try std.testing.expect(found_mount);
    try std.testing.expect(function_named("getCollection") != null);
    try std.testing.expect(function_named("nope") == null);
}

/// The feature that is not a function called `name` (`set:markdown`, `island`), when there
/// is one.
pub fn other_named(name: []const u8) ?Feature {
    std.debug.assert(name.len > 0);

    for (others) |feature| {
        if (std.mem.eql(u8, feature.name, name)) {
            return feature;
        }
    }

    return null;
}
