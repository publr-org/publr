//! Many records of one type made at once, each as `record create` makes it, in one write:
//! seeding a site, importing from elsewhere. A batch is all or nothing.

const std = @import("std");
const public = @import("../../publr/operations/record/create_many.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Problem = sdk.operation.Problem;

/// The most documents one call takes: a batch a request's memory holds with room to spare;
/// `publr seed` sends a file in batches of this size.
pub const documents_max: u32 = 200;
const documents_bytes_max: u32 = 2 << 20;

pub const CreateMany = struct {
    pub const shape = public.CreateMany;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.type.len == 0 or in.type.len > 64 << 10) {
            return error.Invalid;
        }

        const documents = in.documents;

        try check(ctx, documents);

        const ids = ctx.arena.alloc([]const u8, documents.len) catch return error.OutOfMemory;
        const kept = ctx.arena;
        const scratch = try ctx.scratch();

        // Each record made in the request's scratch, given back once made: only its id stays.
        // A refused one keeps its scratch, where its problems are.
        for (documents, ids, 0..) |document, *id, index| {
            const begun = scratch.mark();

            ctx.arena = scratch.allocator();

            const created = registry.SDK.dispatch(ctx, record_operations.Create, .{
                .type = in.type,
                .document = document,
            }) catch |err| {
                ctx.arena = kept;
                return refused(ctx, err, @intCast(index));
            };

            id.* = kept.dupe(u8, created.id) catch return error.OutOfMemory;
            ctx.arena = kept;
            scratch.rewind(begun);
        }

        if (in.publish) {
            for (ids, 0..) |id, index| {
                const begun = scratch.mark();

                ctx.arena = scratch.allocator();

                _ = registry.SDK.dispatch(ctx, record_operations.Transition, .{
                    .id = id,
                    .transition = "publish",
                }) catch |err| {
                    ctx.arena = kept;
                    return refused(ctx, err, @intCast(index));
                };

                ctx.arena = kept;
                scratch.rewind(begun);
            }
        }

        return .{
            .created = @intCast(ids.len),
            .ids = ids,
        };
    }

    /// Refuses an empty batch, one over the limits, or an item that is no object.
    fn check(ctx: *Ctx, documents: []const sdk.operation.Json) Error!void {
        std.debug.assert(documents_max > 0);

        if (documents.len == 0) {
            return ctx.refuse(&.{.{
                .field = "documents",
                .message = "At least one document",
            }});
        }

        if (documents.len > documents_max) {
            return ctx.refuse(&.{.{
                .field = "documents",
                .message = "At most 200 documents a call; `publr seed` sends more in batches",
            }});
        }

        var bytes: u64 = 0;

        for (documents) |document| {
            bytes += document.text.len;

            if (document.text.len == 0 or document.text[0] != '{') {
                return ctx.refuse(&.{.{
                    .field = "documents",
                    .message = "Every item must be a JSON object",
                }});
            }
        }

        if (bytes > documents_bytes_max) {
            return error.Invalid;
        }

        std.debug.assert(documents.len <= documents_max);
    }

    /// One document's refusal as the batch's: its problems, or its failure, named by index.
    fn refused(ctx: *Ctx, err: Error, index: u32) Error {
        std.debug.assert(index < documents_max);

        if (err == error.Invalid) {
            const inner = ctx.problems;
            const problems = ctx.arena.alloc(Problem, @max(inner.len, 1)) catch {
                return error.OutOfMemory;
            };

            for (problems, 0..) |*problem, at| {
                const field = if (at < inner.len) inner[at].field else "";
                const message = if (at < inner.len) inner[at].message else "Refused";

                problem.* = .{
                    .field = std.fmt.allocPrint(ctx.arena, "documents.{d}{s}{s}", .{
                        index,
                        if (field.len > 0) "." else "",
                        field,
                    }) catch return error.OutOfMemory,
                    .message = message,
                };
            }

            return ctx.refuse(problems);
        }

        if (ctx.failure) |failure| {
            return ctx.fail(.{
                .name = failure.name,
                .status = failure.status,
                .message = std.fmt.allocPrint(ctx.arena, "Document {d}: {s}", .{
                    index,
                    failure.message,
                }) catch return error.OutOfMemory,
            });
        }

        return err;
    }
};

const SDK = registry.SDK;

test "create_many: a batch made at once, published on asking, refused whole" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try record_operations.fixture.post_type(&system);

    var editor = harness.ctx(.{
        .user = .{
            .id = "u_ed",
            .roles = &.{"editor"},
        },
    });
    const made = try SDK.dispatch(&editor, CreateMany, .{
        .type = "post",
        .documents = &.{
            .{
                .text = "{\"title\":\"One\",\"body\":\"x\"}",
            },
            .{
                .text = "{\"title\":\"Two\",\"body\":\"y\"}",
            },
        },
        .publish = true,
    });

    try std.testing.expectEqual(@as(u32, 2), made.created);

    const refused_whole = SDK.dispatch(&editor, CreateMany, .{
        .type = "post",
        .documents = &.{
            .{
                .text = "{\"title\":\"Three\",\"body\":\"z\"}",
            },
            .{
                .text = "{\"title\":5}",
            },
        },
    });

    try std.testing.expectError(error.Invalid, refused_whole);
    try std.testing.expect(std.mem.startsWith(u8, editor.problems[0].field, "documents.1"));

    const listed = try SDK.dispatch(&editor, record_operations.List, .{
        .type = "post",
        .filters = &.{"status:is:published"},
        .limit = 1,
        .count = true,
    });

    try std.testing.expectEqual(@as(u32, 2), listed.total);
    try std.testing.expectError(error.Invalid, SDK.dispatch(&editor, CreateMany, .{
        .type = "post",
        .documents = &.{},
    }));
}
