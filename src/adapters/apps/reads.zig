//! What a template reads beyond its route's records: `get(type, id)`, `findOne` and
//! `find(type, { field: value })` (one field, by equality), `query(groq, params)` (GROQ,
//! through `record.query`), and `call(name, input)`, which runs a plugin's `app.*` read for
//! the visitor, and `media(id)`, the file a media field names.

const std = @import("std");
const registry = @import("../../server/registry.zig");
const record_operations = @import("../../operations/record.zig");
const identity_module = @import("../rest/identity.zig");
const json = @import("../../lib/json.zig");
const context_module = @import("context.zig");
const changes = @import("../../operations/project/changes.zig");
const media_view = @import("../../operations/media/view.zig");

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

/// `media(id)`: the file a media field names, as JSON (its address, alt text, size), or
/// null when there is none the visitor may see.
pub fn media(ctx: *const Context, id: []const u8) !?[]const u8 {
    std.debug.assert(id.len <= std.math.maxInt(u32));
    std.debug.assert(ctx.app.spec.name.len > 0);

    if (id.len == 0 or id.len > 64) {
        return null;
    }

    if (ctx.deps) |deps| {
        deps.record_key(id);
    }

    var sdk_ctx = ctx.sdk_context();
    const viewed = registry.SDK.dispatch(&sdk_ctx, media_view.View, .{
        .id = id,
    }) catch |err| switch (err) {
        error.NotFound, error.Invalid => return null,
        else => return err,
    };

    return try std.json.Stringify.valueAlloc(sdk_ctx.arena, viewed, .{});
}

/// `call(name, input)`: a plugin's read made with `publr.operation.define`, installed or built
/// in, as the visitor for the app; or a built-in operation that allows frontmatter calls. Its
/// output is the entry's `data`; a refusal is a blank entry.
pub fn call_with(ctx: *const Context, operation: []const u8, input: []const u8) !Entry {
    std.debug.assert(operation.len > 0);
    std.debug.assert(ctx.project.connection.transaction_depth == 0);

    const blank = try ctx.reference(&.{});

    if (ctx.request == null) {
        return blank;
    }

    const name = resolved(ctx, operation);

    if (!try callable(ctx, name)) {
        return error.FrontmatterCallRefused;
    }

    var sdk_ctx = identity_module.context(ctx.project, ctx.arena, ctx.caller);

    sdk_ctx.app = ctx.app.spec.name;
    sdk_ctx.app_plugins = ctx.app.spec.plugins;
    sdk_ctx.app_reach = ctx.app.spec.name;
    sdk_ctx.visitor = ctx.visitor_id;

    const given = if (input.len > 0) input else "{}";
    const output = registry.SDK.call_json(&sdk_ctx, name, given) catch {
        return blank;
    };
    const document = json.parse(std.json.Value, ctx.arena, output, .{}) catch return blank;

    if (document != .object) {
        return blank;
    }

    var result = blank;

    result.data = .{
        .arena = ctx.arena,
        .document = document,
    };

    return result;
}

/// `app.cart.view` names `cart.view`, its address and its name the same operation.
fn resolved(_: *const Context, operation: []const u8) []const u8 {
    std.debug.assert(operation.len > 0);

    if (!std.mem.startsWith(u8, operation, "app.")) {
        return operation;
    }

    const own = operation["app.".len..];

    std.debug.assert(own.len > 0);

    return own;
}

/// Whether a page may run `operation` when it renders: any read, as the visitor, its
/// authorization deciding. Never a write: a GET changes nothing.
fn callable(ctx: *const Context, operation: []const u8) !bool {
    std.debug.assert(operation.len > 0);
    std.debug.assert(ctx.app.spec.name.len > 0);

    inline for (registry.SDK.operations) |Operation| {
        if (std.mem.eql(u8, Operation.name, operation)) {
            return Operation.kind == .read;
        }
    }

    const sandboxed = ctx.project.sandboxed_plugins orelse return false;
    const found = sandboxed.find(operation) orelse return false;

    return found.kind == .read;
}
