//! One registration: `pub const plugin = publr.plugin.define(manifest, options)`. The words
//! come from the plugin's doc comments, which the build hands over beside it; core pairs the
//! two and reads the options (`sdk/plugin/bound.zig`).
const std = @import("std");
const doc_reader = @import("../../sdk/plugin/doc_reader.zig");

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
};

/// The manifest every reader takes: the name and version, and the description from `//!`.
pub const Described = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
};

pub fn Definition(comptime Options: type) type {
    return struct {
        manifest: Manifest,
        options: Options,
    };
}

pub fn define(comptime manifest: Manifest, comptime options: anytype) Definition(@TypeOf(options)) {
    comptime {
        std.debug.assert(manifest.name.len > 0);
        std.debug.assert(manifest.version.len > 0);

        return .{
            .manifest = manifest,
            .options = options,
        };
    }
}

/// Whether `Module` registers through `define`.
pub fn defined(comptime Module: type) bool {
    comptime {
        std.debug.assert(@typeInfo(Module) == .@"struct");

        if (!@hasDecl(Module, "plugin")) {
            return false;
        }

        const Value = @TypeOf(Module.plugin);

        return @typeInfo(Value) == .@"struct" and @hasField(Value, "manifest") and
            @hasField(Value, "options") and Value == Definition(@TypeOf(Module.plugin.options));
    }
}

pub fn listed_in(comptime names: []const []const u8, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        for (names) |candidate| {
            if (std.mem.eql(u8, candidate, name)) {
                return true;
            }
        }

        return false;
    }
}

/// none.
pub fn words(comptime Docs: type, comptime key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    return Docs.get(key);
}

/// A doc comment's first line: a name, a label, a summary.
pub fn first(comptime Docs: type, comptime key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    return Docs.first(key);
}

/// What a doc comment says after its first line.
pub fn rest(comptime Docs: type, comptime key: []const u8) ?[]const u8 {
    std.debug.assert(key.len > 0);

    return Docs.rest(key);
}

/// Words written by hand, for a test: `Words(.{ .{ "main", "..." } })`. A plugin's come from
/// its source, found by name and split already (`doc_reader.generated`).
pub fn Words(comptime entries: anytype) type {
    return struct {
        pub fn get(comptime key: []const u8) ?[]const u8 {
            return part(key, .text);
        }

        pub fn first(comptime key: []const u8) ?[]const u8 {
            return part(key, .first);
        }

        pub fn rest(comptime key: []const u8) ?[]const u8 {
            return part(key, .rest);
        }

        fn part(comptime key: []const u8, comptime which: enum { text, first, rest }) ?[]const u8 {
            std.debug.assert(key.len > 0);

            inline for (entries) |entry| {
                if (comptime std.mem.eql(u8, entry[0], key)) {
                    const parts = comptime doc_reader.split(entry[1]);

                    return switch (which) {
                        .text => entry[1],
                        .first => parts.first,
                        .rest => parts.rest,
                    };
                }
            }

            return null;
        }
    };
}
