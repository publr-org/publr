//! What a template reads beyond its route's records: `get(type, id)`, `findOne` and
//! `find(type, { field: value })` (one field, by equality), `query(groq, params)` (GROQ,
//! through `record.query`), and `call(name, input)`, which runs a plugin's `app.*` read for
//! the visitor.

const std = @import("std");
const registry = @import("../../server/registry.zig");
const record_operations = @import("../../operations/record.zig");
const identity_module = @import("../rest/identity.zig");
const json = @import("../../lib/json.zig");
const context_module = @import("context.zig");
const changes = @import("../../operations/project/changes.zig");

const Context = context_module.Context;
const Entry = Context.Entry;

/// The live record `id` when it is of `type_id`, or null.
pub fn get_record(ctx: *const Context, type_id: []const u8, id: []const u8) !?Entry {
    std.debug.assert(type_id.len > 0);

    if (id.len == 0) {
        return null;
    }

    const found = ctx.load(id) catch |err| switch (err) {
        error.EntryNotFound => return null,
        else => return err,
    };

    return if (std.mem.eql(u8, found.type, type_id)) found else null;
}

/// Live records of `type_id`, newest first; with a `field`, only those whose field holds
/// `value`. One query for the page and its documents.
pub fn find_records(
    ctx: *const Context,
    type_id: []const u8,
    field: []const u8,
    value: []const u8,
    limit: u32,
    offset: u32,
) ![]const Entry {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(limit <= record_operations.list_max);

    if (ctx.deps) |deps| {
        deps.record_type(type_id);
    }

    var sdk_ctx = ctx.sdk_context();
    const listed = registry.SDK.dispatch(&sdk_ctx, record_operations.List, .{
        .type = type_id,
        .filter_field = if (field.len > 0) field else null,
        .filter_value = if (field.len > 0) value else null,
        .order = .created_desc,
        .limit = @max(limit, 1),
        .offset = offset,
        .documents = true,
    }) catch |err| switch (err) {
        error.NotFound => return &.{},
        else => return err,
    };
    const entries = try ctx.arena.alloc(Entry, listed.records.len);

    for (listed.records, listed.documents, entries) |row, text, *out| {
        out.* = try ctx.adopt(row, text);
    }

    return entries;
}

/// `query(groq, params)`: a GROQ query as the page's reader, its answer as JSON. A static
/// page depends on every record then: any change rebuilds it. A query the engine refuses
/// fails the render, saying why.
pub fn run_query(ctx: *const Context, groq: []const u8, params: []const u8) ![]const u8 {
    std.debug.assert(groq.len > 0);
    std.debug.assert(params.len > 0);

    if (ctx.deps) |deps| {
        deps.record_key(changes.all_records_key);
    }

    var sdk_ctx = ctx.sdk_context();
    const answered = registry.SDK.dispatch(&sdk_ctx, record_operations.Query, .{
        .query = groq,
        .params = params,
    }) catch |err| {
        const message = if (sdk_ctx.failure) |failure| failure.message else @errorName(err);

        std.log.warn("query refused: {s}", .{message});

        return error.QueryRefused;
    };

    return answered.result.text;
}

/// `call(name, input)`: a plugin's `app.*` read, installed or built in, as the visitor for
/// the app; or a built-in operation that allows frontmatter calls. Its output is the
/// entry's `data`; a refusal is a blank entry.
pub fn call_with(ctx: *const Context, operation: []const u8, input: []const u8) !Entry {
    std.debug.assert(operation.len > 0);
    std.debug.assert(ctx.project.connection.transaction_depth == 0);

    const blank = try ctx.reference(&.{});

    if (ctx.request == null) {
        return blank;
    }

    if (!try callable(ctx, operation)) {
        return error.FrontmatterCallRefused;
    }

    var sdk_ctx = identity_module.context(ctx.project, ctx.arena, ctx.caller);

    sdk_ctx.app = ctx.app.spec.name;
    sdk_ctx.app_plugins = ctx.app.spec.plugins;
    sdk_ctx.visitor = ctx.visitor_id;

    const given = if (input.len > 0) input else "{}";
    const output = registry.SDK.call_json(&sdk_ctx, operation, given) catch {
        return blank;
    };
    const document = json.parse(std.json.Value, ctx.arena, output, .{}) catch return blank;

    if (document != .object) {
        return blank;
    }

    var result = blank;

    result.data = .{ .arena = ctx.arena, .document = document };

    return result;
}

/// A page may run an `app.*` read, or a built-in operation that allows frontmatter calls.
fn callable(ctx: *const Context, operation: []const u8) !bool {
    std.debug.assert(operation.len > 0);

    const app = std.mem.startsWith(u8, operation, "app.");

    inline for (registry.SDK.operations) |Operation| {
        if (std.mem.eql(u8, Operation.name, operation)) {
            const allowed = @hasDecl(Operation, "allow_frontmatter_calls") and
                Operation.allow_frontmatter_calls;

            return allowed or (app and Operation.kind == .read);
        }
    }

    const sandboxed = ctx.project.sandboxed_plugins orelse return false;
    const found = sandboxed.find(operation) orelse return false;

    return app and found.kind == .read;
}
