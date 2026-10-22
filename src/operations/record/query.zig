//! `record.query`: a GROQ query (GROQ-1.revision5) over the content. The engine evaluates
//! it; the records it reads come through `record.list` as the caller may read them
//! (`query_dataset.zig`), narrowed by what the query's filters say.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const access = @import("../document/access.zig");
const query_dataset = @import("query_dataset.zig");

const groq = @import("../../lib/groq.zig");
const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const answer_bytes_max: u32 = 2 << 20;
/// About how many evaluation steps run in a millisecond: what turns a CPU limit into a
/// work budget.
pub const steps_per_ms: u64 = 20_000;
/// The work a query may do for a page or a person: about a second.
pub const work_steps_default: u64 = 1000 * steps_per_ms;

pub const Problem = struct {
    /// The record a reference points at.
    id: []const u8,
    /// `status` (not in the statuses read), `owner` (not the caller's own), `type` (a type
    /// out of reach).
    reason: []const u8,
    message: []const u8,
};

pub const Query = struct {
    pub const name = "record.query";
    pub const description = "Ask for content with a GROQ query, nested records and all";
    pub const details =
        \\A GROQ query (GROQ-1.revision5, spec.groq.dev): `*[_type == "product" && slug ==
        \\$slug][0]{ title, "variants": *[_type == "variant" && product == ^._id] |
        \\order(price.GBP) }`. All of the language but its extensions, custom functions,
        \\delta mode and vendor functions. It reads what the caller may: the types their grant
        \\reaches (a visitor: public ones), every status the grant allows with perspective
        \\`all` (the default), each record's latest copy for a signed-in caller, or live
        \\records only with `published` (a visitor's and a site page's only one), without
        \\the fields the grant hides. A query naming a type out of reach is refused as
        \\`Denied`; a reference to a record the caller may not read is `null`, listed in
        \\`problems`. References are record ids: `product == ^._id` compares them, `->`
        \\follows them. Records in the trash are left out unless `trashed` asks for them.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        query: []const u8,
        /// `$name` values, a JSON object.
        params: []const u8 = "{}",
        perspective: Perspective = .all,
        /// Records in the trash too.
        trashed: bool = false,
    };
    pub const Perspective = enum { published, all };
    pub const Out = struct {
        result: sdk.operation.Json,
        /// References the caller may not follow, made `null`: which record, and why.
        problems: []const Problem = &.{},
    };
    pub const example: In = .{
        .query = "*[_type == \"post\" && slug == $slug][0]{ title }",
        .params = "{\"slug\":\"hello-world\"}",
    };
    pub const example_out: Out = .{
        .result = .{
            .text = "{\"title\":\"Hello, world\"}",
        },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .query = "The GROQ query",
        .params = "Its `$name` values, as a JSON object",
        .perspective = "`published` (live records) or `all` (every status the grant allows)",
        .trashed = "Read records in the trash too",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .result = "What the query answers: a list, one record, a value, or null",
        .problems = "Each reference made `null` because you may not read its record, and why",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.query.len == 0 or in.query.len > 16 << 10 or in.params.len > 64 << 10) {
            return error.Invalid;
        }

        const arena = ctx.arena;
        const params = try params_of(arena, in.params);
        var source = try source_of(ctx, granted, in.perspective);

        source.trashed = in.trashed and source.live == null;
        var problem: groq.Problem = .{};
        const now: groq.values.Datetime = .{
            .seconds = @divFloor(ctx.now_ms, 1000),
            .nanoseconds = @intCast(@mod(ctx.now_ms, 1000) * 1_000_000),
        };
        const answered = groq.execute(arena, in.query, source.dataset(), &problem, .{
            .params = params,
            .now = now,
            .strings_are_references = true,
            .work_steps = work_budget(ctx),
        }) catch |err| return refused(ctx, err, problem, source.refused_type);
        const text = groq.values.to_json(arena, answered.value) catch return error.OutOfMemory;

        if (text.len > answer_bytes_max) {
            return ctx.fail(.{
                .name = "TooLarge",
                .status = 413,
                .message = "the answer is too large: take fewer with a slice, `[0...50]`",
            });
        }

        const problems = try problems_of(arena, answered.problems);

        return .{
            .result = .{
                .text = text,
            },
            .problems = problems,
        };
    }
};

fn params_of(arena: std.mem.Allocator, text: []const u8) Error!groq.values.Object {
    std.debug.assert(text.len <= 64 << 10);

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    const converted = groq.values.from_json(arena, parsed) catch return error.OutOfMemory;

    return converted.object;
}

/// A plugin's query runs within its CPU limit; a page's or a person's within the default.
fn work_budget(ctx: *const Ctx) u64 {
    std.debug.assert(steps_per_ms > 0);

    if (ctx.plugin.len == 0) {
        return work_steps_default;
    }

    const cpu_ms: u64 = model.sandboxed_plugin.limits_default.cpu_ms;

    return cpu_ms * steps_per_ms;
}

fn refused(ctx: *Ctx, err: groq.Error, problem: groq.Problem, refused_type: []const u8) Error {
    std.debug.assert(problem.message.len <= 4096);

    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => ctx.fail(.{
            .name = "InvalidQuery",
            .status = 400,
            .message = std.fmt.allocPrint(ctx.arena, "{s} (at {d})", .{
                problem.message,
                problem.at,
            }) catch return error.OutOfMemory,
        }),
        error.TooDeep => ctx.fail(.{
            .name = "InvalidQuery",
            .status = 400,
            .message = "the query nests too deep",
        }),
        error.TooMuchWork => ctx.fail(.{
            .name = "TooMuchWork",
            .status = 422,
            .message = "the query asks for more work than a call may do: " ++
                "narrow its filters or take fewer with a slice, `[0...50]`",
        }),
        error.OutOfReach => blk: {
            std.log.debug("record.query: `{s}` is out of reach", .{refused_type});
            break :blk error.Denied;
        },
        error.DatasetFailed => error.Failed,
    };
}

fn problems_of(
    arena: std.mem.Allocator,
    found: []const groq.evaluation.Problem,
) Error![]const Problem {
    const problems = arena.alloc(Problem, found.len) catch return error.OutOfMemory;

    for (found, problems) |each, *problem| {
        const why = if (std.mem.eql(u8, each.reason, "owner"))
            "it is someone else's, and your access reaches only your own"
        else if (std.mem.eql(u8, each.reason, "type"))
            "its type is out of your reach"
        else
            "it is not published, or in a status your access does not read";

        problem.* = .{
            .id = each.id,
            .reason = each.reason,
            .message = std.fmt.allocPrint(arena, "a reference to {s} was made null: {s}", .{
                each.id,
                why,
            }) catch return error.OutOfMemory,
        };
    }

    return problems;
}

const types_chunk: u32 = 100;

/// What the caller may read: the readable types, the statuses by perspective, the fields
/// the grant hides.
fn source_of(
    ctx: *Ctx,
    granted: *const Grant,
    perspective: Query.Perspective,
) Error!query_dataset.Source {
    std.debug.assert(granted.allows());

    const arena = ctx.arena;
    var readable: std.ArrayList(query_dataset.Type) = .empty;
    var out_of_reach: std.ArrayList([]const u8) = .empty;
    const filter = granted.record_filter;
    const visitor = ctx.caller == .anonymous;
    const public_only = visitor or filter.flags.public_types_only;
    const scratch = try ctx.scratch();
    var key_name: [256]u8 = undefined;
    var key_name_len: u32 = 0;
    var key_id: [256]u8 = undefined;
    var key_id_len: u32 = 0;

    // The types a chunk at a time, their briefs only: what is kept is each one's handle.
    while (true) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const briefs = store.content_types.briefs_after(ctx.db, scratch.allocator(), .{
            .name = key_name[0..key_name_len],
            .id = key_id[0..key_id_len],
        }, types_chunk) catch return error.Failed;

        for (briefs) |brief| {
            const shared = model.content_type.shared_of(.{
                .handle = brief.handle,
                .name = brief.name,
                .app = brief.app,
                .shared = brief.shared,
                .fields = &.{},
            });
            const in_reach = granted.allows_type(brief.handle) and
                granted.allows_owner(brief.owner) and
                granted.allows_placement(brief.app, shared);
            const visible = !public_only or brief.public or !(visitor or
                granted.public_only_on(brief.handle));
            const handle = try arena.dupe(u8, brief.handle);

            if (in_reach and visible and kind_readable(ctx, brief.kind, brief.public)) {
                readable.append(arena, .{
                    .handle = handle,
                    .live_only = granted.live_only_on(brief.handle, brief.public),
                }) catch return error.OutOfMemory;
            } else {
                out_of_reach.append(arena, handle) catch return error.OutOfMemory;
            }
        }

        if (briefs.len < types_chunk) {
            break;
        }

        const last = briefs[briefs.len - 1];

        std.debug.assert(last.name.len <= key_name.len and last.id.len <= key_id.len);

        @memcpy(key_name[0..last.name.len], last.name);
        key_name_len = @intCast(last.name.len);
        @memcpy(key_id[0..last.id.len], last.id);
        key_id_len = @intCast(last.id.len);
    }

    // Each type by its own grant: one read live only leaves the others' drafts readable.
    const live_only = visitor or perspective == .published;
    const live = try live_statuses(ctx, granted);

    return .{
        .ctx = ctx,
        .granted = granted,
        .types = readable.items,
        .out_of_reach = out_of_reach.items,
        .live = if (live_only) live else null,
        .live_statuses = live,
        .mask = granted.field_mask,
        .owner = if (filter.flags.own_only) try own_user(ctx) else null,
        .users = @import("query_dataset/users.zig").reach_of(ctx),
    };
}

/// The caller whose own records a grant limits a query to; only a signed-in user has any.
fn own_user(ctx: *const Ctx) Error![]const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    return ctx.caller.user_id() orelse error.Denied;
}

/// Records and settings singletons, as when a list names its type; a settings type only for
/// a caller whose roles reach settings, or every caller when it is public. Components hold
/// no records.
fn kind_readable(ctx: *const Ctx, kind: model.content_type.Kind, public: bool) bool {
    std.debug.assert(ctx.now_ms >= 0);

    return switch (kind) {
        .record => true,
        .settings => public or !access.settings_denied(ctx),
        else => false,
    };
}

fn live_statuses(ctx: *Ctx, granted: *const Grant) Error![]const []const u8 {
    std.debug.assert(granted.allows());

    const known = try @import("../status.zig").known(ctx);
    var list: std.ArrayList([]const u8) = .empty;

    for (known) |status| {
        if (status.live and granted.allows_status(status.id)) {
            list.append(ctx.arena, status.id) catch return error.OutOfMemory;
        }
    }

    return list.items;
}

test {
    _ = @import("query_tests.zig");
}
