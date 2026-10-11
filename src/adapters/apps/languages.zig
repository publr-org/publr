//! The site's languages as its addresses: a page under a language's address (`/pl/about`)
//! is the app's `/about` read in that language, and every root path it writes keeps the
//! address. The main language has none. A site without languages has no places at all.
const std = @import("std");
const model = @import("../../model.zig");
const variants = @import("../../operations/variants.zig");
const identity_module = @import("../rest/identity.zig");

const Project = @import("../../server/project.zig").Project;
const Target = Project.Target;
const Place = model.variant.Place;

/// Every language's place, the main one first; empty on a site without languages.
pub fn places(project: *const Project, arena: std.mem.Allocator) ![]const Place {
    std.debug.assert(project.connection.transaction_depth == 0);

    var ctx = identity_module.context(project, arena, .anonymous);
    const listed = try variants.listed(&ctx);
    const out = try arena.alloc(Place, listed.len);

    for (listed, out) |variant, *place| {
        place.* = .{
            .variant = if (variant.main) "" else variant.code,
            .locale = variant.code,
            .address = if (variant.main) "" else variant.address,
        };
    }

    std.debug.assert(out.len == listed.len);

    return out;
}

/// The target as the language it is under: its address taken off the path.
pub fn locate(project: *const Project, arena: std.mem.Allocator, target: Target) !Target {
    std.debug.assert(target.path.len > 0);
    std.debug.assert(target.place.address.len == 0);

    const all = try places(project, arena);
    var located = target;

    for (all) |place| {
        if (place.address.len < 2) {
            located.place = if (place.variant.len == 0) place else located.place;

            continue;
        }

        if (model.variant.beneath(place.address, target.path)) |rest| {
            located.path = rest;
            located.place = place;

            return located;
        }
    }

    return located;
}
