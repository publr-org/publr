//! Many records of one type made at once, each as `record create` makes it, in one write:
//! seeding a site, importing from elsewhere. A batch is all or nothing.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const record_operations = @import("../record.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Problem = sdk.operation.Problem;

/// The most documents one call takes: a batch a request's memory holds with room to spare;
/// `publr seed` sends a file in batches of this size.
pub const documents_max: u32 = 250;
const documents_bytes_max: u32 = 2 << 20;

pub const CreateMany = struct {
    pub const name = "record.create_many";
    pub const description = "Create many records of a type at once, from a JSON array of documents";
    pub const details =
        \\Each document is made as `record create` makes it, its checks, hooks and events
        \\included, all in one write: up to 250 a call (`publr seed` sends a file of any size
        \\in calls of 250). The batch is all or nothing: one document refused refuses them all,
        \\its problems named `documents.<index>.<field>`. With `publish`, each is published
        \\as `record transition --transition publish` would, once all are made.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        type: []const u8,
        /// A JSON array of documents, as `record create` takes one.
        documents: []const u8,
        publish: bool = false,
    };
    pub const Out = struct {
        created: u32,
        ids: []const []const u8,
    };
    pub const example: In = .{
        .type = "post",
        .documents = "[{\"title\":\"First\",\"body\":\"One\"},{\"title\":\"Second\"}]",
    };
    pub const example_out: Out = .{
        .created = 2,
        .ids = &.{ record_operations.example_id, record_operations.example_changed_id },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The content type, by handle or id",
        .documents = "The documents as a JSON array of objects, at most 250",
        .publish = "Publish each one once all are made",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .created = "How many records were made",
        .ids = "Their ids, in the documents' order",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.type.len == 0 or in.type.len > 64 << 10 or in.documents.len > documents_bytes_max) {
            return error.Invalid;
        }

        const documents = try documents_of(ctx, in.documents);
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

    /// Each document of the array as its own JSON text, as `record create` takes it.
    fn documents_of(ctx: *Ctx, text: []const u8) Error![]const []const u8 {
        std.debug.assert(documents_max > 0);

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, text, .{}) catch {
            return ctx.refuse(&.{.{
                .field = "documents",
                .message = "Not a JSON array of objects",
            }});
        };

        if (parsed != .array or parsed.array.items.len == 0) {
            return ctx.refuse(&.{.{
                .field = "documents",
                .message = "A JSON array with at least one object",
            }});
        }

        if (parsed.array.items.len > documents_max) {
            return ctx.refuse(&.{.{
                .field = "documents",
                .message = "At most 250 documents a call; `publr seed` sends more in batches",
            }});
        }

        const documents = ctx.arena.alloc([]const u8, parsed.array.items.len) catch {
            return error.OutOfMemory;
        };

        for (parsed.array.items, documents) |item, *document| {
            if (item != .object) {
                return ctx.refuse(&.{.{
                    .field = "documents",
                    .message = "Every item must be a JSON object",
                }});
            }

            document.* = std.json.Stringify.valueAlloc(ctx.arena, item, .{}) catch {
                return error.OutOfMemory;
            };
        }

        return documents;
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
        .documents = "[{\"title\":\"One\",\"body\":\"x\"},{\"title\":\"Two\",\"body\":\"y\"}]",
        .publish = true,
    });

    try std.testing.expectEqual(@as(u32, 2), made.created);

    const refused_whole = SDK.dispatch(&editor, CreateMany, .{
        .type = "post",
        .documents = "[{\"title\":\"Three\",\"body\":\"z\"},{\"title\":5}]",
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
        .documents = "{}",
    }));
}
