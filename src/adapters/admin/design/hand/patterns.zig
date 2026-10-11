//! The app's patterns as the editor's library takes them: its files, each replaced by a
//! record of its name, then the records that add one, with their variants and color
//! settings.
const std = @import("std");
const admin = @import("../../../admin.zig");
const design = @import("../../../../model/design.zig");
const files = @import("../files.zig");
const records = @import("../records.zig");
const App = @import("../../../apps/state.zig").App;

const Session = admin.Session;

/// One pattern as the editor's library takes it.
pub const Pattern = struct {
    name: []const u8,
    label: []const u8,
    category: []const u8,
    description: []const u8,
    html: []const u8,
    /// `file`, `overridden` or `added`: where it comes from, for the Design pages.
    source: []const u8,
    variants: []const records.Variant = &.{},
    default_variant: []const u8 = "",
    default_color_context: []const u8 = "",
    disabled_color_contexts: []const []const u8 = &.{},
};

/// The app's patterns: its files, each replaced by a record of its name, then the records
/// that add one.
pub fn patterns_of(session: *Session, app: *const App) ![]const Pattern {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const from_files = try files.file_patterns(session, app);
    const saved = try records.list(session, design.pattern_handle, app.spec.name, null);
    var out: std.ArrayList(Pattern) = .empty;

    for (from_files) |file| {
        const pattern = file.pattern;

        try out.append(arena, .{
            .name = file.name,
            .label = if (pattern.label.len > 0) pattern.label else file.name,
            .category = pattern.category,
            .description = pattern.description,
            .html = pattern.html,
            .source = "file",
        });
    }

    for (saved) |record| {
        try merge(arena, &out, record.document);
    }

    return out.items;
}

fn merge(arena: std.mem.Allocator, out: *std.ArrayList(Pattern), document: records.Document) !void {
    std.debug.assert(document.name.len <= 4096);

    if (!design.valid_name(document.name)) {
        return;
    }

    const pattern: Pattern = .{
        .name = document.name,
        .label = if (document.label.len > 0) document.label else document.name,
        .category = document.category,
        .description = document.description,
        .html = document.html,
        .source = "added",
        .variants = document.variants,
        .default_variant = document.default_variant,
        .default_color_context = document.default_color_context,
        .disabled_color_contexts = document.disabled_color_contexts,
    };

    for (out.items) |*existing| {
        if (std.mem.eql(u8, existing.name, document.name)) {
            if (std.mem.eql(u8, existing.source, "file")) {
                existing.* = pattern;
                existing.source = "overridden";
            }

            return;
        }
    }

    try out.append(arena, pattern);
}

pub fn patterns_json(session: *Session, app: *const App) ![]const u8 {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(session.signed_in());

    const found = try patterns_of(session, app);

    return shown_json(session.arena, found);
}

/// The patterns as `data-editor-patterns` carries them: where each comes from left out.
fn shown_json(arena: std.mem.Allocator, found: []const Pattern) ![]const u8 {
    const Shown = struct {
        name: []const u8,
        label: []const u8,
        category: []const u8,
        description: []const u8,
        html: []const u8,
        variants: []const records.Variant,
        default_variant: []const u8,
        default_color_context: []const u8,
        disabled_color_contexts: []const []const u8,
    };
    const shown = try arena.alloc(Shown, found.len);

    for (found, shown) |pattern, *out| {
        std.debug.assert(pattern.name.len > 0);

        out.* = .{
            .name = pattern.name,
            .label = pattern.label,
            .category = pattern.category,
            .description = pattern.description,
            .html = pattern.html,
            .variants = pattern.variants,
            .default_variant = pattern.default_variant,
            .default_color_context = pattern.default_color_context,
            .disabled_color_contexts = pattern.disabled_color_contexts,
        };
    }

    std.debug.assert(shown.len == found.len);

    return std.json.Stringify.valueAlloc(arena, shown, .{});
}

test "merge and shown_json: a record over a file keeps its variants for the editor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(Pattern) = .empty;
    const variants = [_]records.Variant{
        .{
            .name = "light",
            .label = "Light",
            .html = "<p>a</p>",
        },
        .{
            .name = "dark",
            .label = "Dark",
            .html = "<p>b</p>",
        },
    };

    try out.append(arena, .{
        .name = "hero",
        .label = "Hero",
        .category = "Banners",
        .description = "",
        .html = "<p>file</p>",
        .source = "file",
    });
    try merge(arena, &out, .{
        .name = "hero",
        .label = "Hero",
        .html = "<p>a</p>",
        .variants = &variants,
        .default_variant = "dark",
    });
    try merge(arena, &out, .{
        .name = "bad name",
        .html = "<p>x</p>",
    });

    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("overridden", out.items[0].source);

    const text = try shown_json(arena, out.items);

    try std.testing.expect(std.mem.indexOf(u8, text, "\"default_variant\":\"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"name\":\"light\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"source\"") == null);
}
