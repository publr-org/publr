//! Dispatch the common field editor to its schema owner.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const types = @import("../../operations/content_type.zig");
const custom = @import("../../operations/custom_fields.zig");
const taxonomies = @import("../../operations/taxonomy.zig");
const model = @import("../../model.zig");
const spaces = @import("schema_space.zig");

pub fn load(session: *admin.Session, handle: []const u8) !types.Get.Out {
    std.debug.assert(session.signed_in());
    const space = spaces.of(session);

    if (space == .taxonomies) {
        const got = try registry.SDK.dispatch(&session.ctx, taxonomies.Get, .{
            .taxonomy = handle,
        });
        return .{
            .id = got.id,
            .definition = got.definition,
            .created_at = got.created_at,
            .updated_at = got.updated_at,
        };
    }

    if (space == .custom) {
        const got = try registry.SDK.dispatch(&session.ctx, custom.Get, .{
            .group = handle,
        });
        return .{
            .id = handle,
            .definition = got.definition,
            .created_at = 0,
            .updated_at = 0,
        };
    }

    const got = try registry.SDK.dispatch(&session.ctx, types.Get, .{
        .type = handle,
    });

    if (got.definition.kind != space.kind()) {
        return error.NotFound;
    }

    return got;
}

pub fn update(
    session: *admin.Session,
    handle: []const u8,
    definition: model.content_type.Def,
    drop: bool,
) !void {
    std.debug.assert(session.signed_in());

    if (spaces.of(session) == .taxonomies) {
        _ = try registry.SDK.dispatch(
            &session.ctx,
            taxonomies.Update,
            .{
                .taxonomy = handle,
                .definition = definition,
                .drop_content = drop,
            },
        );
    } else if (spaces.of(session) == .custom) {
        _ = try registry.SDK.dispatch(&session.ctx, custom.Update, .{
            .group = handle,
            .definition = definition,
        });
    } else {
        _ = try registry.SDK.dispatch(&session.ctx, types.Update, .{
            .type = handle,
            .definition = definition,
            .drop_content = drop,
        });
    }
}

pub fn problems(
    session: *admin.Session,
    err: anyerror,
    definition: model.content_type.Def,
) admin.Error![]const model.field.Problem {
    std.debug.assert(session.signed_in());

    if (spaces.of(session) == .taxonomies) {
        return @import("taxonomies.zig").problems_of(session, err, definition);
    }

    if (spaces.of(session) != .custom or err != error.Invalid) {
        return @import("types.zig").problems_of(session, err, definition);
    }

    const handle = session.request.param("handle") orelse return error.OutOfMemory;
    const report = registry.SDK.dispatch(&session.ctx, custom.Validate, .{
        .group = handle,
        .definition = definition,
    }) catch |failure| {
        if (failure == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        const one = try session.arena.alloc(model.field.Problem, 1);
        one[0] = .{
            .path = "",
            .message = try session.translated("The field schema is too large or invalid.", .{}),
        };
        return one;
    };
    return report.problems;
}
