//! Serves the site's media from another address.
//!
//! A plugin the sandbox is tested with: it keeps one address and answers it through the mod
//! `media.base`, so every media address Publr writes starts there.
const std = @import("std");
const publr = @import("publr");

const manifest: publr.Manifest = .{
    .name = "mirror",
    .version = "0.1.0",
};

pub const Kept = struct {
    /// Where the site's media is served from
    origin: []const u8 = "",
};

pub const record = publr.record.define(Kept, .{
    .name = "mirror.origin",
    .internal = true,
});

const kept_id = publr.query.prepare(
    \\*[_type == "mirror.origin"] | order(_createdAt desc) [0]._id
, .{});

pub const SetIn = struct {
    /// The address media is served from: an origin, a path under it at most
    origin: []const u8,
};

pub const SetOut = struct {
    /// The address kept
    origin: []const u8,
};

/// Keeps the address the site's media is served from.
///
/// Example:
///   in: { "origin": "https://cdn.example.com" }
///   out: { "origin": "https://cdn.example.com" }
pub const Set = publr.operation.define(SetIn, SetOut, .{
    .name = "set",
    .kind = .write,
    .run = set,
});

fn set(ctx: *publr.Ctx, in: SetIn) publr.Error!SetOut {
    std.debug.assert(ctx.now().ms >= 0);

    if (in.origin.len > 512) {
        return error.Invalid;
    }

    if (try kept_id.execute(ctx, ?[]const u8, .{})) |id| {
        const held = try record.get(ctx, id, .{});

        _ = try record.save(ctx, held, .{
            .origin = in.origin,
        });
    } else {
        _ = try record.create(ctx, .{
            .origin = in.origin,
        });
    }

    // The pages built with the old address are built again.
    _ = try ctx.call(publr.mod_changed, .{
        .name = "media.base",
    });

    return .{
        .origin = in.origin,
    };
}

/// The value core applies as `media.base`.
pub const Base = struct {
    base: []const u8 = "",
};

/// Starts every media address at the kept origin
fn based(ctx: *publr.Ctx, value: *Base) publr.Error!void {
    std.debug.assert(ctx.now().ms >= 0);

    const id = try kept_id.execute(ctx, ?[]const u8, .{}) orelse return;
    const kept = try record.get(ctx, id, .{});

    std.debug.assert(kept.id.len > 0);

    value.base = kept.value.origin;
}

pub const plugin = publr.plugin.define(manifest, .{
    .operations = &.{Set},
    .records = &.{record},
    .hooks = .{
        publr.modify("media.base", based),
    },
});
