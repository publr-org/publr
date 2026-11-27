//! How a type's records are edited, beside its `editor` (`form` or `visual`).
const std = @import("std");
const written = @import("../../model/editor.zig");

/// A type's `editor_config`: `{"field": name}`, the rich text field a visual type writes;
/// `{}` for its first one.
pub const Config = struct {
    field: []const u8 = "",

    pub const publr_form = .fields;

    pub fn jsonStringify(config: Config, writer: anytype) !void {
        return written.write_config(config, writer);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !Config {
        const value = try std.json.Value.jsonParse(allocator, source, options);

        return written.config_of(allocator, value, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        source: std.json.Value,
        options: std.json.ParseOptions,
    ) !Config {
        return written.config_of(allocator, source, options);
    }
};
