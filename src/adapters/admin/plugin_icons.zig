//! Plugins' own icons in the admin (`publr.Icon`): a sprite of their drawings written into
//! every page beside the set's, each drawing through the sanitizer first (`lib/sanitize.zig`,
//! its SVG rules), core writing the `<symbol>` around it; and the split every view needs
//! between an icon of the set and a plugin's (`Icon`'s `custom_icon`).
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const sanitize = @import("../../lib/sanitize.zig");

const Session = admin.Session;
const Error = admin.Error;
const PluginIcon = model.sandboxed_plugin.PluginIcon;

pub const icons_max: u32 = 128;

/// An icon as a view takes it: one of the set, or a plugin's own with the set's `fallback`
/// beside it.
pub fn Picked(comptime Icon: type) type {
    return struct {
        icon: Icon,
        custom_icon: []const u8,
    };
}

/// `name` as a view takes it: one of the set by its name; a plugin's (`products.bag`) when
/// some plugin brings it; anything else, the fallback.
pub fn pick(
    comptime Icon: type,
    session: *const Session,
    name: []const u8,
    fallback: Icon,
) Picked(Icon) {
    std.debug.assert(session.signed_in());

    if (std.meta.stringToEnum(Icon, name)) |icon| {
        return .{
            .icon = icon,
            .custom_icon = "",
        };
    }

    const brought = find(session, name) != null;

    return .{
        .icon = fallback,
        .custom_icon = if (brought) name else "",
    };
}

fn find(session: *const Session, name: []const u8) ?PluginIcon {
    std.debug.assert(session.signed_in());

    if (std.mem.indexOfScalar(u8, name, '.') == null) {
        return null;
    }

    for (registry.icons) |icon| {
        if (std.mem.eql(u8, icon.name, name)) {
            return icon;
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return null;

    for (sandboxed.manifests()) |manifest| {
        for (manifest.icons) |icon| {
            if (std.mem.eql(u8, icon.name, name)) {
                return icon;
            }
        }
    }

    return null;
}

/// The page's sprite of plugins' icons; null when no plugin brings one.
pub fn sprite(session: *const Session) Error!?admin.render.Node {
    std.debug.assert(session.signed_in());

    var out: std.Io.Writer.Allocating = .init(session.arena);
    var count: u32 = 0;

    for (registry.icons) |icon| {
        count += @intFromBool(try write_symbol(session.arena, &out.writer, icon));
    }

    if (session.ctx.sandboxed_plugins) |sandboxed| {
        for (sandboxed.manifests()) |manifest| {
            for (manifest.icons) |icon| {
                if (count == icons_max) {
                    break;
                }

                count += @intFromBool(try write_symbol(session.arena, &out.writer, icon));
            }
        }
    }

    if (count == 0) {
        return null;
    }

    const written = std.fmt.allocPrint(session.arena, "<svg id=\"publr-plugin-icons\" " ++
        "style=\"position:absolute;width:0;height:0;overflow:hidden\" aria-hidden=\"true\">" ++
        "{s}</svg>", .{out.written()}) catch return error.OutOfMemory;

    return admin.render.raw(written);
}

/// One drawing as a `<symbol>`: its name checked, its markup sanitized, only what is inside
/// its `<svg>` kept. A drawing that does not come through is left out.
fn write_symbol(arena: std.mem.Allocator, writer: *std.Io.Writer, icon: PluginIcon) Error!bool {
    std.debug.assert(icon.name.len > 0);

    const sized = icon.svg.len <= model.sandboxed_plugin.plugin_icon_bytes_max;

    if (!model.sandboxed_plugin.icon_name_valid(icon.name) or !sized) {
        return false;
    }

    const cleaned = sanitize.sanitize(arena, icon.svg, .content) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else false;
    };
    const inner = inner_of(cleaned) orelse return false;

    const symbol = "<symbol id=\"publr-icon-{s}\" viewBox=\"0 0 24 24\" fill=\"none\">{s}</symbol>";

    writer.print(symbol, .{
        icon.name,
        inner,
    }) catch return error.OutOfMemory;

    return true;
}

/// What sits inside the one `<svg>` the sanitizer wrote; null when it wrote anything else.
fn inner_of(cleaned: []const u8) ?[]const u8 {
    std.debug.assert(cleaned.len <= sanitize.input_bytes_max * 2);

    const trimmed = std.mem.trim(u8, cleaned, " \n\r\t");

    if (!std.mem.startsWith(u8, trimmed, "<svg") or !std.mem.endsWith(u8, trimmed, "</svg>")) {
        return null;
    }

    const open_end = std.mem.indexOfScalar(u8, trimmed, '>') orelse return null;
    const inside = trimmed[open_end + 1 .. trimmed.len - "</svg>".len];

    if (std.mem.indexOf(u8, inside, "<svg") != null) {
        return null;
    }

    return inside;
}

test "a plugin's drawing comes through as its drawing, never as anything that runs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);

    const bag: PluginIcon = .{
        .name = "products.bag",
        .svg = "<svg viewBox=\"0 0 24 24\"><path d=\"M5 8h14\" stroke=\"currentColor\"/></svg>",
    };
    const hostile: PluginIcon = .{
        .name = "evil.icon",
        .svg = "<svg onload=\"alert(1)\"><script>alert(1)</script>" ++
            "<path d=\"M1 1\" onclick=\"x()\" style=\"fill:red\"/></svg>",
    };
    const misnamed: PluginIcon = .{
        .name = "evil.\"><script>",
        .svg = "<svg><path d=\"M1 1\"/></svg>",
    };

    try std.testing.expect(try write_symbol(arena, &out.writer, bag));
    try std.testing.expect(try write_symbol(arena, &out.writer, hostile));
    try std.testing.expect(!try write_symbol(arena, &out.writer, misnamed));

    const written = out.written();

    try std.testing.expect(std.mem.indexOf(u8, written, "id=\"publr-icon-products.bag\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "d=\"M5 8h14\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "script") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "onload") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "onclick") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "style") == null);
}
