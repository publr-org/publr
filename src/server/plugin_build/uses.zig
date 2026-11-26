//! What a built module uses of Publr and of other plugins, read from its bytes (the host
//! functions it imports, the `publr_uses:` marks its calls left) and from its manifest (what
//! it hooks and modifies), written into its manifest with the Publr it was built with:
//! `minimum_publr`, `tested_up_to`, `uses`.
const std = @import("std");
const wasm = @import("publr_wasm");
const plugin_manifest = @import("../../sdk/plugin/manifest.zig");

/// The manifest `manifest` (JSON, an object) with `minimum_publr` and `tested_up_to` set to
/// `publr_version` and `uses` to what the plugin uses, sorted, each once.
pub fn stamped(
    arena: std.mem.Allocator,
    module: []const u8,
    manifest: []const u8,
    publr_version: []const u8,
) ![]const u8 {
    std.debug.assert(manifest.len > 0);
    std.debug.assert(publr_version.len > 0);

    var parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, manifest, .{});

    if (parsed != .object) {
        return error.InvalidManifest;
    }

    const all = try std.mem.concat(arena, []const u8, &.{
        try used(arena, module),
        try hooked(arena, parsed.object.get("hooks")),
    });
    var names: std.json.Array = .init(arena);

    for (once(all)) |name| {
        try names.append(.{
            .string = name,
        });
    }

    try parsed.object.put(arena, "minimum_publr", .{
        .string = publr_version,
    });
    try parsed.object.put(arena, "tested_up_to", .{
        .string = publr_version,
    });
    try parsed.object.put(arena, "uses", .{
        .array = names,
    });

    return std.json.Stringify.valueAlloc(arena, parsed, .{});
}

/// What `module` uses: the host functions it imports (`host:publr_call`) and what its calls
/// marked (`call:money.texts`, `emit:…`, `mod:…`).
pub fn used(arena: std.mem.Allocator, module: []const u8) ![]const []const u8 {
    std.debug.assert(module.len > 0);

    const imported = try wasm.names.imported_functions(arena, module, "env");
    const marked = try wasm.names.exported_with(arena, module, plugin_manifest.uses_prefix);
    const all = try arena.alloc([]const u8, imported.len + marked.len);

    for (imported, all[0..imported.len]) |name, *host| {
        host.* = try std.fmt.allocPrint(arena, "host:{s}", .{name});
    }

    @memcpy(all[imported.len..], marked);

    std.debug.assert(all.len == imported.len + marked.len);

    return all;
}

/// What the manifest's hooks reach: an operation or event a `before`, `after` or event hook
/// runs on (`hook:record.save`), a mod a modifier answers (`mod:media.base`). A target with
/// a `*` names many and is left out.
fn hooked(arena: std.mem.Allocator, hooks: ?std.json.Value) ![]const []const u8 {
    const listed = hooks orelse return &.{};

    if (listed != .array) {
        return error.InvalidManifest;
    }

    var found: std.ArrayList([]const u8) = .empty;

    for (listed.array.items) |hook| {
        if (hook != .object) {
            return error.InvalidManifest;
        }

        const stage = hook.object.get("stage") orelse continue;
        const target = hook.object.get("target") orelse continue;

        if (stage != .string or target != .string or target.string.len == 0 or
            std.mem.indexOfScalar(u8, target.string, '*') != null)
        {
            continue;
        }

        const kind = if (std.mem.eql(u8, stage.string, "modify")) "mod" else "hook";

        try found.append(arena, try std.fmt.allocPrint(arena, "{s}:{s}", .{
            kind,
            target.string,
        }));
    }

    std.debug.assert(found.items.len <= listed.array.items.len);

    return found.items;
}

/// `all` sorted, each once, in place.
fn once(all: [][]const u8) []const []const u8 {
    std.mem.sortUnstable([]const u8, all, {}, before);

    var kept: u32 = 0;

    for (all) |name| {
        if (kept > 0 and std.mem.eql(u8, all[kept - 1], name)) {
            continue;
        }

        all[kept] = name;
        kept += 1;
    }

    std.debug.assert(kept <= all.len);

    return all[0..kept];
}

fn before(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

test "a module's imports, marks and hooks become its uses, with the Publr it was built with" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    // (import "env" "publr_call" (func 0))
    // (export "publr_uses:call:money.texts" (global 0))
    // (export "publr_uses:call:languages.get" (global 1)) (export "run" (func 0))
    const module = "\x00asm\x01\x00\x00\x00" ++
        "\x01\x04\x01\x60\x00\x00" ++
        "\x02\x12\x01\x03env\x0apublr_call\x00\x00" ++
        "\x07\x45\x03" ++
        "\x1bpublr_uses:call:money.texts\x03\x00" ++
        "\x1dpublr_uses:call:languages.get\x03\x01" ++
        "\x03run\x00\x00";
    const manifest =
        \\{"name":"deposits","uses":["old"],"hooks":[
        \\{"stage":"after","target":"record.save","reason":"r"},
        \\{"stage":"modify","target":"media.base","reason":"r"},
        \\{"stage":"modify","target":"*.title","reason":"r"}]}
    ;
    const text = try stamped(arena, module, manifest, "0.8.2");
    const Read = struct {
        name: []const u8,
        minimum_publr: []const u8,
        tested_up_to: []const u8,
        uses: []const []const u8,
    };
    const read = try std.json.parseFromSliceLeaky(Read, arena, text, .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expectEqualStrings("deposits", read.name);
    try std.testing.expectEqualStrings("0.8.2", read.minimum_publr);
    try std.testing.expectEqualStrings("0.8.2", read.tested_up_to);
    try std.testing.expectEqual(@as(usize, 5), read.uses.len);
    try std.testing.expectEqualStrings("call:languages.get", read.uses[0]);
    try std.testing.expectEqualStrings("call:money.texts", read.uses[1]);
    try std.testing.expectEqualStrings("hook:record.save", read.uses[2]);
    try std.testing.expectEqualStrings("host:publr_call", read.uses[3]);
    try std.testing.expectEqualStrings("mod:media.base", read.uses[4]);
    try std.testing.expectError(error.InvalidManifest, stamped(arena, module, "[]", "0.8.2"));
}
