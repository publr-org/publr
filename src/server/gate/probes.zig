const std = @import("std");

/// Types and taxonomies probed a page at a time.
const probe_page: u32 = 200;
const db = @import("../../lib/db.zig");
const auth = @import("../../lib/auth.zig");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const registry = @import("../registry.zig");
const user = @import("../../operations/user.zig");
const record = @import("../../operations/record.zig");
const term = @import("../../operations/term.zig");
const content_type = @import("../../operations/content_type.zig");
const taxonomy = @import("../../operations/taxonomy.zig");

const probe_password = "probe-password-not-kept";

/// What the probes found: a write the database refused, with SQLite's words.
pub const Failure = struct {
    what: []const u8,
    message: []const u8,
};

/// A write through every door that tables tend to break: a user with each role, a record of
/// each content type, a term of each taxonomy. Each goes through the real operation, inside
/// a savepoint that is always rolled back, so nothing stays. A refusal the operation would
/// give anyone (the document is not valid, a field is required) is fine; the database
/// refusing the write is not, and is returned.
pub fn run(
    connection: *db.Db,
    io: std.Io,
    arena: std.mem.Allocator,
    auth_state: *auth.State,
    now_ms: i64,
) !?Failure {
    std.debug.assert(now_ms > 0);
    std.debug.assert(connection.transaction_depth <= 1);

    var savepoint = try connection.transaction();
    defer savepoint.rollback();

    var ctx = sdk.Ctx.init(
        connection,
        io,
        arena,
        auth_state,
        .system,
        .{
            .now_ms = now_ms,
        },
    );

    for (try store.roles.list(connection, arena), 0..) |role, index| {
        const email = try std.fmt.allocPrint(arena, "probe-{d}@probe.publr.invalid", .{index});
        const created = registry.SDK.dispatch(&ctx, user.Create, .{
            .email = email,
            .display_name = "Probe",
            .roles = &.{role.name},
            .password = probe_password,
        });

        if (try refused(connection, arena, created, "user with role", role.name)) |failure| {
            return failure;
        }
    }

    var offset: u32 = 0;

    // A page of types at a time: as many as the project has.
    while (true) : (offset += probe_page) {
        const types = registry.SDK.dispatch(&ctx, content_type.List, .{
            .offset = offset,
            .limit = probe_page,
        }) catch |err| return failure_of(connection, arena, err, "content types", "list");

        for (types.types) |summary| {
            if (summary.kind != .record) {
                continue;
            }

            const scratch = try ctx.scratch();
            const begun = scratch.mark();
            defer scratch.rewind(begun);

            var probing = ctx;

            probing.arena = scratch.allocator();

            const created = registry.SDK.dispatch(&probing, record.Create, .{
                .type = summary.handle,
                .document = "{}",
            });

            if (try refused(connection, arena, created, "record of", summary.handle)) |failure| {
                return failure;
            }
        }

        if (types.types.len < probe_page) {
            break;
        }
    }

    return taxonomies(connection, arena, &ctx);
}

fn taxonomies(connection: *db.Db, arena: std.mem.Allocator, ctx: *sdk.Ctx) !?Failure {
    std.debug.assert(connection.transaction_depth >= 1);
    std.debug.assert(ctx.caller == .system);

    var offset: u32 = 0;

    while (true) : (offset += probe_page) {
        const list = registry.SDK.dispatch(ctx, taxonomy.List, .{
            .offset = offset,
            .limit = probe_page,
        }) catch |err| return failure_of(connection, arena, err, "taxonomies", "list");

        for (list.taxonomies) |summary| {
            const scratch = try ctx.scratch();
            const begun = scratch.mark();
            defer scratch.rewind(begun);

            var probing = ctx.*;

            probing.arena = scratch.allocator();

            const created = registry.SDK.dispatch(&probing, term.Create, .{
                .taxonomy = summary.handle,
                .document = "{}",
            });

            if (try refused(connection, arena, created, "term of", summary.handle)) |failure| {
                return failure;
            }
        }

        if (list.taxonomies.len < probe_page) {
            return null;
        }
    }
}

/// Whether `outcome` is the database refusing, rather than the operation.
fn refused(
    connection: *db.Db,
    arena: std.mem.Allocator,
    outcome: anytype,
    what: []const u8,
    name: []const u8,
) !?Failure {
    std.debug.assert(what.len > 0);
    std.debug.assert(name.len > 0);

    _ = outcome catch |err| return failure_of(connection, arena, err, what, name);

    return null;
}

fn failure_of(
    connection: *db.Db,
    arena: std.mem.Allocator,
    err: sdk.Error,
    what: []const u8,
    name: []const u8,
) !?Failure {
    std.debug.assert(what.len > 0);
    std.debug.assert(name.len > 0);

    return switch (err) {
        error.Invalid, error.NotFound, error.Denied, error.Conflict, error.Vetoed => null,
        error.Failed, error.Throttled, error.Unavailable => null,
        error.OutOfMemory => error.OutOfMemory,
        else => .{
            .what = try std.fmt.allocPrint(arena, "{s} {s}", .{ what, name }),
            .message = try std.fmt.allocPrint(arena, "{t}: {s}", .{ err, connection.message() }),
        },
    };
}
