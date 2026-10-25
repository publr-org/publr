//! An installed plugin's translations, read from its module's `publr.translations` section as
//! it loads: the same PO files a compiled-in plugin embeds, joined to the catalogues the
//! admin and the site look words up in. An installed plugin never speaks as Publr's own
//! translation (`official`): it translates, and a choice between it and another stays the
//! administrator's.
const std = @import("std");
const wasm = @import("publr_wasm");
const plugin_contract = @import("../../sdk/plugin.zig");
const plugin_manifest = @import("../../sdk/plugin/manifest.zig");

const OwnedTranslation = plugin_contract.OwnedTranslation;
const Translation = plugin_contract.Translation;

/// One plugin brings at most this many PO files.
pub const per_plugin_max: u32 = 256;

/// The translations `bytes` (a module, before it is loaded) carries for `plugin`, in `arena`.
/// None for a module without the section; a section that does not read is logged and left
/// out, the plugin loading all the same.
pub fn of(
    arena: std.mem.Allocator,
    plugin: []const u8,
    bytes: []const u8,
) error{OutOfMemory}![]const OwnedTranslation {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(bytes.len > 0);

    const name = plugin_manifest.translations_section_name;
    const section = wasm.section.find(bytes, name) catch return &.{};
    const text = section orelse return &.{};
    const brought = std.json.parseFromSliceLeaky([]const Translation, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.log.warn("plugin {s}: its translations do not read: {t}", .{ plugin, err });
            return &.{};
        },
    };

    if (brought.len > per_plugin_max) {
        std.log.warn("plugin {s}: more than {d} translations; none taken", .{
            plugin,
            per_plugin_max,
        });
        return &.{};
    }

    const owned = try arena.alloc(OwnedTranslation, brought.len);
    const owner = try arena.dupe(u8, plugin);

    for (brought, owned) |translation, *slot| {
        var taken = translation;

        taken.official = false;
        slot.* = .{
            .plugin = owner,
            .translation = taken,
        };
    }

    return owned;
}

test "a module's translations are read with their plugin, never as official" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const json =
        \\[{"locale":"pl","label":"Polski","domain":"publr","official":true,
        \\  "po":"msgid \"Save\"\nmsgstr \"Zapisz\"\n"}]
    ;
    var module: std.Io.Writer.Allocating = .init(arena);

    try module.writer.writeAll(&.{ 0, 'a', 's', 'm', 1, 0, 0, 0 });
    try wasm.section.write(&module.writer, plugin_manifest.translations_section_name, json);

    const read = try of(arena, "language_pl", module.written());

    try std.testing.expectEqual(@as(usize, 1), read.len);
    try std.testing.expectEqualStrings("language_pl", read[0].plugin);
    try std.testing.expectEqualStrings("pl", read[0].translation.locale);
    try std.testing.expect(!read[0].translation.official);

    const plain = [_]u8{ 0, 'a', 's', 'm', 1, 0, 0, 0 };

    try std.testing.expectEqual(@as(usize, 0), (try of(arena, "other", &plain)).len);
}
