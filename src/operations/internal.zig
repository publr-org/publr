const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/internal.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const changes = @import("project/changes.zig");
const rules = @import("internal/rules.zig");
const computed = @import("internal/computed.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Value = std.json.Value;
const Collection = model.internal_record.Collection;
const Scope = store.internal_records.Scope;
const records = store.internal_records;

pub const namespace = public.namespace;

pub const Item = public.Item;

pub const operations = [_]type{
    Create,
    CreateMany,
    Get,
    Save,
    SaveMany,
    FindOne,
    Find,
    Count,
    Delete,
    computed_operations.Sum,
    computed_operations.HoldsUntil,
};

pub const Sum = computed_operations.Sum;
pub const HoldsUntil = computed_operations.HoldsUntil;
const computed_operations = @import("internal/computed_operations.zig");

pub const Create = struct {
    pub const shape = public.Create;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        return created(ctx, in, granted, true);
    }

    /// The record made; its computed values worked out now when `compute`, else by the
    /// caller with others (`create_many`).
    fn created(ctx: *Ctx, in: In, granted: *const Grant, compute: bool) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind, true);
        const given = try object_of(ctx, in.document.text);
        const scope = target.scope;

        try rules.check(ctx, target.collection, scope, given, null, null);

        const document = in.document.text;
        const id = try records.insert(ctx.db, ctx.io, ctx.arena, scope, document, ctx.now_ms);

        // Records meant to vanish go as new ones come: no cleanup job, no trash step.
        if (target.collection.expires) |expires| {
            const cutoff = ctx.now_ms - @as(i64, expires.after_days) * std.time.ms_per_day;

            const from = expires.from;
            const gone = try records.delete_expired(ctx.db, scope.plugin, scope.kind, from, cutoff);

            if (gone > 0) {
                raised(ctx, scope, null);
            }
        }

        try index(ctx, scope, target.collection, id, given);
        try changed(ctx, Created, scope, id);

        if (compute) {
            try computed.written(ctx, scope, target.collection, id, document);
        }

        // A job following one of its times (`.due`) is queued at it.
        try SDK.jobs.follow(ctx, id);

        return .{
            .id = id,
            .version = 1,
        };
    }
};

pub const many_max = public.many_max;

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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.documents.len > many_max) {
            return ctx.refuse(&.{.{
                .field = "documents",
                .message = "At most 200 records a call",
            }});
        }

        const ids = ctx.arena.alloc([]const u8, in.documents.len) catch return error.OutOfMemory;
        const kept = ctx.arena;
        const scratch = try ctx.scratch();

        // Each record made in the request's scratch, given back once made: only its id
        // stays. A refused one keeps its scratch, where its problems are.
        for (in.documents, ids, 0..) |document, *id, place| {
            const begun = scratch.mark();

            ctx.arena = scratch.allocator();

            const made = Create.created(ctx, .{
                .kind = in.kind,
                .document = document,
                .plugin = in.plugin,
                .app = in.app,
            }, granted, false) catch |err| {
                ctx.arena = kept;
                return refused_at(ctx, err, "documents", place);
            };

            ctx.arena = kept;
            id.* = kept.dupe(u8, made.id) catch return error.OutOfMemory;
            scratch.rewind(begun);
        }

        std.debug.assert(ids.len == in.documents.len);

        try written_together(ctx, in.plugin, in.app, in.kind, ids);

        if (SDK.bulk.hooked(ctx, Create)) {
            const inputs = kept.alloc(Create.In, ids.len) catch return error.OutOfMemory;
            const outputs = kept.alloc(Create.Out, ids.len) catch return error.OutOfMemory;

            for (in.documents, ids, inputs, outputs) |document, id, *input, *output| {
                input.* = .{
                    .kind = in.kind,
                    .document = document,
                    .plugin = in.plugin,
                    .app = in.app,
                };
                output.* = .{
                    .id = id,
                    .version = 1,
                };
            }

            try heard_after(ctx, Create, inputs, outputs, "documents");
        }

        return .{
            .ids = ids,
        };
    }
};

pub const Get = struct {
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind, false);

        try drawn(ctx, target, in.id);

        var row = [_]records.Row{
            try records.get(ctx.db, ctx.arena, target.scope, in.id) orelse {
                return error.NotFound;
            },
        };

        try computed.freshen(ctx, target.scope, target.collection, &row);

        return item_of(ctx, target.collection, row[0]);
    }
};

/// Fields one `internal.save` may empty.
pub const clear_max: u32 = 64;

pub const Save = struct {
    pub const shape = public.Save;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        return saved(ctx, in, granted, true);
    }

    /// The record written; its computed values worked out now when `compute`, else by the
    /// caller with others (`save_many`).
    fn saved(ctx: *Ctx, in: In, granted: *const Grant, compute: bool) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind, true);

        if (target.collection.append_only) {
            return error.Invalid;
        }

        const given = try object_of(ctx, in.document.text);
        const row = try records.get(ctx.db, ctx.arena, target.scope, in.id) orelse {
            return error.NotFound;
        };
        var merged = try object_of(ctx, row.document);
        var fields = given.object.iterator();

        while (fields.next()) |field| {
            // Worked out after the write, whatever the caller sent for it.
            if (model.internal_record.computes(target.collection, field.key_ptr.*)) {
                continue;
            }

            try merged.object.put(ctx.arena, field.key_ptr.*, field.value_ptr.*);
        }

        if (in.clear.len > clear_max) {
            return error.Invalid;
        }

        for (in.clear) |cleared| {
            _ = merged.object.orderedRemove(cleared);
        }

        const text = std.json.Stringify.valueAlloc(ctx.arena, merged, .{}) catch {
            return error.OutOfMemory;
        };

        if (text.len > model.internal_record.document_bytes_max) {
            return error.Invalid;
        }

        const before = if (target.collection.rules.len > 0)
            try object_of(ctx, row.document)
        else
            null;

        try rules.check(ctx, target.collection, target.scope, merged, before, in.id);

        const expected = in.expected_version;
        const version = try records.update(ctx.db, target.scope, in.id, text, expected, ctx.now_ms);

        try index(ctx, target.scope, target.collection, in.id, merged);
        try changed(ctx, Saved, target.scope, in.id);

        if (compute) {
            try computed.written(ctx, target.scope, target.collection, in.id, text);
        }

        // A time it holds moved: the job following it moves too.
        try SDK.jobs.follow(ctx, in.id);

        return .{
            .version = version,
        };
    }
};

pub const SaveMany = struct {
    pub const shape = public.SaveMany;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const Written = shape.Written;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.records.len > many_max) {
            return ctx.refuse(&.{.{
                .field = "records",
                .message = "At most 200 records a call",
            }});
        }

        const kept = ctx.arena;
        const scratch = try ctx.scratch();
        const outputs = kept.alloc(Save.Out, in.records.len) catch return error.OutOfMemory;

        for (in.records, 0..) |record, place| {
            const begun = scratch.mark();

            ctx.arena = scratch.allocator();

            const saved = Save.saved(ctx, .{
                .kind = in.kind,
                .id = record.id,
                .document = record.document,
                .plugin = in.plugin,
                .app = in.app,
            }, granted, false) catch |err| {
                ctx.arena = kept;
                return refused_at(ctx, err, "records", place);
            };

            ctx.arena = kept;
            outputs[place] = .{
                .version = saved.version,
            };
            scratch.rewind(begun);
        }

        std.debug.assert(in.records.len <= many_max);

        const ids = kept.alloc([]const u8, in.records.len) catch return error.OutOfMemory;

        for (in.records, ids) |record, *id| {
            id.* = record.id;
        }

        try written_together(ctx, in.plugin, in.app, in.kind, ids);

        if (SDK.bulk.hooked(ctx, Save)) {
            const inputs = kept.alloc(Save.In, outputs.len) catch return error.OutOfMemory;

            for (in.records, inputs) |record, *input| {
                input.* = .{
                    .kind = in.kind,
                    .id = record.id,
                    .document = record.document,
                    .plugin = in.plugin,
                    .app = in.app,
                };
            }

            try heard_after(ctx, Save, inputs, outputs, "records");
        }

        return .{
            .saved = @intCast(in.records.len),
        };
    }
};

/// The `after` hooks on `Operation` (a record's `.validate` among them) over every record
/// a write of many wrote: each installed plugin's hook is entered once for all of them. The
/// first record a hook refuses refuses the call, named at its place under `<list>.<index>`.
fn heard_after(
    ctx: *Ctx,
    comptime Operation: type,
    inputs: []const Operation.In,
    outputs: []const Operation.Out,
    comptime list: []const u8,
) Error!void {
    std.debug.assert(inputs.len == outputs.len);
    std.debug.assert(inputs.len <= many_max);

    const refused = ctx.arena.alloc(?[]const u8, inputs.len) catch return error.OutOfMemory;

    @memset(refused, null);
    try SDK.bulk.after_each(ctx, Operation, inputs, outputs, refused);

    for (refused, 0..) |reason, place| {
        const why = reason orelse continue;
        const field = std.fmt.allocPrint(ctx.arena, list ++ ".{d}", .{place}) catch {
            return error.OutOfMemory;
        };

        const problems = ctx.arena.alloc(sdk.operation.Problem, 1) catch {
            return error.OutOfMemory;
        };

        problems[0] = .{
            .field = field,
            .message = why,
        };

        return ctx.refuse(problems);
    }
}

fn refused_at(ctx: *Ctx, err: Error, comptime list: []const u8, place: u64) Error {
    std.debug.assert(place < many_max);

    if (err != error.Invalid or ctx.problems.len == 0) {
        return err;
    }

    const inner = ctx.problems;
    const problems = ctx.arena.alloc(sdk.operation.Problem, inner.len) catch {
        return error.OutOfMemory;
    };

    for (inner, problems) |problem, *one| {
        one.* = .{
            .field = std.fmt.allocPrint(ctx.arena, list ++ ".{d}.{s}", .{
                place,
                problem.field,
            }) catch return error.OutOfMemory,
            .message = problem.message,
        };
    }

    return ctx.refuse(problems);
}

pub const FindOne = struct {
    pub const shape = public.FindOne;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind, false);

        const match = try match_of(target.collection, in.field, in.value);

        try drawn_matched(ctx, target, match);

        const rows = try records.list(ctx.db, ctx.arena, target.scope, match, 2, 0);

        if (rows.len > 1) {
            return error.Conflict;
        }

        try computed.freshen(ctx, target.scope, target.collection, rows);

        return .{
            .record = if (rows.len == 1) try item_of(ctx, target.collection, rows[0]) else null,
        };
    }
};

pub const Find = struct {
    pub const shape = public.Find;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const fields_max = shape.fields_max;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.limit < 1 or in.limit > sdk.operation.page_limit_max) {
            return ctx.refuse(&.{.{
                .field = "limit",
                .message = "A page is 1 to 200 records.",
            }});
        }

        const paired = (in.field == null) == (in.value == null);
        const by_id = in.ids.len > 0;

        if (!paired or in.fields.len > fields_max or in.ids.len > many_max) {
            return error.Invalid;
        }

        // By id or by a field: never both.
        if (by_id and in.field != null) {
            return error.Invalid;
        }

        // A walk continues from a record, never from a count of them.
        if (in.after) |after| {
            if (by_id or in.offset > 0 or after.len > records.id_bytes_max) {
                return error.Invalid;
            }
        }

        const target = try scope_of(ctx, in.plugin, in.app, in.kind, false);

        const match = try matching(target.collection, in.field, in.value);

        if (by_id) {
            for (in.ids) |id| {
                try drawn(ctx, target, id);
            }
        } else {
            try drawn_matched(ctx, target, match);
        }

        const rows = if (by_id)
            try records_named(ctx, target.scope, in.ids)
        else
            try records.listed(ctx.db, ctx.arena, target.scope, match, .{
                .limit = in.limit,
                .offset = in.offset,
                .oldest = in.oldest,
                .after = in.after,
            });

        try computed.freshen(ctx, target.scope, target.collection, rows);

        const items = ctx.arena.alloc(Item, rows.len) catch return error.OutOfMemory;

        for (rows, items) |row, *target_item| {
            target_item.* = try item_of(ctx, target.collection, row);

            if (in.fields.len > 0) {
                target_item.document.text = try only(ctx, target_item.document.text, in.fields);
            }
        }

        return .{
            .records = items,
        };
    }
};

/// The scope's records of `ids`, in the order named; an id with no record there is left out.
fn records_named(ctx: *Ctx, scope: records.Scope, ids: []const []const u8) Error![]records.Row {
    std.debug.assert(ids.len > 0);
    std.debug.assert(ids.len <= many_max);

    const rows = ctx.arena.alloc(records.Row, ids.len) catch return error.OutOfMemory;
    var found: u32 = 0;

    for (ids) |id| {
        if (id.len == 0 or id.len > 64) {
            continue;
        }

        if (try records.get(ctx.db, ctx.arena, scope, id)) |row| {
            rows[found] = row;
            found += 1;
        }
    }

    return rows[0..found];
}

pub fn matching(
    collection: Collection,
    field: ?[]const u8,
    value: ?[]const u8,
) Error!?records.Match {
    std.debug.assert((field == null) == (value == null));

    return if (field) |named| try match_of(collection, named, value.?) else null;
}

/// `document` with only its fields named in `fields`.
fn only(ctx: *const Ctx, document: []const u8, fields: []const []const u8) Error![]const u8 {
    std.debug.assert(fields.len > 0);
    std.debug.assert(fields.len <= Find.fields_max);

    return model.json_fields.only(ctx.arena, document, fields);
}

pub const Count = struct {
    pub const shape = public.Count;
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

        if ((in.field == null) != (in.value == null)) {
            return error.Invalid;
        }

        const target = try scope_of(ctx, in.plugin, in.app, in.kind, false);

        const match = try matching(target.collection, in.field, in.value);

        try drawn_matched(ctx, target, match);

        return .{
            .count = try records.count(ctx.db, target.scope, match),
        };
    }
};

pub const Delete = struct {
    pub const shape = public.Delete;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const target = try scope_of(ctx, in.plugin, in.app, in.kind, true);

        if (target.collection.append_only) {
            return error.Invalid;
        }

        const before = try store.internal_record_values.values_of(ctx.db, ctx.arena, in.id);

        try store.internal_record_values.replace(ctx.db, in.id, &.{});
        raised_matched(ctx, target.scope, before, &.{});

        const deleted = try records.delete(ctx.db, target.scope, in.id);

        try changed(ctx, Deleted, target.scope, in.id);
        try computed.forget(ctx, target.scope, target.collection, in.id);

        return .{
            .deleted = deleted,
        };
    }
};

pub const Target = struct {
    scope: Scope,
    collection: Collection,
};

/// Whose records a call reaches: the running plugin's in the request's app; with no plugin
/// running, the ones named. Not found when the plugin declares no such collection.
/// What a write changed, for whoever listens (the activity log names it as a unit):
/// `internal.saved` with `<plugin>/<kind>/<id>`.
fn changed(ctx: *Ctx, comptime Event: type, scope: Scope, id: []const u8) Error!void {
    std.debug.assert(id.len > 0);

    const unit = std.fmt.allocPrint(ctx.arena, "{s}/{s}/{s}", .{
        scope.plugin,
        scope.kind,
        id,
    }) catch return error.OutOfMemory;

    ctx.emit(Event, .{
        .record = unit,
    });
    raised(ctx, scope, id);
}

/// The keys of what a write changed, in its transaction; one that cannot be raised fails
/// the write, as a record's does.
fn raised(ctx: *Ctx, scope: Scope, id: ?[]const u8) void {
    std.debug.assert(scope.plugin.len > 0);
    std.debug.assert(scope.kind.len > 0);

    changes.internal_changed(ctx, scope.plugin, scope.kind, id) catch |err| {
        std.log.debug("internal records: not raised: {s}", .{@errorName(err)});
        ctx.dependency_failure = true;
    };
}

/// What a page being drawn for the built site read: the record (`id`) and whatever takes
/// every record of its collection away, or the collection it looked records up in.
pub fn drawn(ctx: *Ctx, target: Target, id: ?[]const u8) Error!void {
    std.debug.assert(target.scope.plugin.len > 0);
    std.debug.assert(target.scope.kind.len > 0);

    if (ctx.reads == null) {
        return;
    }

    var buffer: [changes.key_len_max]u8 = undefined;
    const scope = target.scope;
    const ids: []const ?[]const u8 = if (id) |record_id|
        &.{ record_id, changes.internal_every }
    else
        &.{null};

    for (ids) |which| {
        const key = changes.internal_key(&buffer, scope.plugin, scope.kind, which) catch {
            return error.Invalid;
        };

        ctx.depends_on(key);
    }
}

/// What a list read: by an indexed value, the records holding it
/// (`internal:<plugin>/<kind>/<field>=<value>`) and whatever takes every record away; else
/// the whole collection. A cart's lines read this way change with that cart's lines only.
pub fn drawn_matched(ctx: *Ctx, target: Target, match: ?records.Match) Error!void {
    std.debug.assert(target.scope.plugin.len > 0);
    std.debug.assert(target.scope.kind.len > 0);

    if (ctx.reads == null) {
        return;
    }

    const wanted = match orelse return drawn(ctx, target, null);
    var buffer: [changes.key_len_max]u8 = undefined;
    const scope = target.scope;
    const matched = changes.internal_match_key(&buffer, scope.plugin, scope.kind, .{
        .field = wanted.field,
        .value = wanted.value,
    }) catch return error.Invalid;

    ctx.depends_on(matched);

    const all = changes.internal_every;
    const every = changes.internal_key(&buffer, scope.plugin, scope.kind, all) catch {
        return error.Invalid;
    };

    ctx.depends_on(every);
}

/// The values a record is found by, before and after a write: each raised, so what looked
/// records up by either hears of it. One that cannot be raised fails the write.
fn raised_matched(
    ctx: *Ctx,
    scope: Scope,
    before: []const store.internal_record_values.Value,
    after: []const store.internal_record_values.Value,
) void {
    std.debug.assert(before.len <= model.internal_record.indexed_max);
    std.debug.assert(after.len <= model.internal_record.indexed_max);

    var matched: [2 * changes.matched_max]changes.Matched = undefined;
    var count: u32 = 0;

    for ([_][]const store.internal_record_values.Value{ before, after }) |values| {
        for (values) |value| {
            matched[count] = .{
                .field = value.field,
                .value = value.value,
            };
            count += 1;
        }
    }

    changes.internal_matched(ctx, scope.plugin, scope.kind, matched[0..count]) catch |err| {
        std.log.debug("internal records: values not raised: {s}", .{@errorName(err)});
        ctx.dependency_failure = true;
    };
}

pub const Changed = public.Changed;
pub const Created = public.Created;
pub const Saved = public.Saved;
pub const Deleted = public.Deleted;

pub fn scope_of(
    ctx: *Ctx,
    plugin: ?[]const u8,
    app: ?[]const u8,
    kind: []const u8,
    writes: bool,
) Error!Target {
    std.debug.assert(ctx.now_ms >= 0);

    if (kind.len == 0 or kind.len > model.internal_record.kind_len_max) {
        return error.Invalid;
    }

    const running = ctx.plugin.len > 0;

    if (running and (plugin != null or app != null)) {
        const other = plugin != null and !std.mem.eql(u8, plugin.?, ctx.plugin);

        if (plugin == null or app != null) {
            return error.Denied;
        }

        if (other and !try reaches_other(ctx, plugin.?, kind, writes)) {
            return error.Denied;
        }
    }

    const owner = if (running) plugin orelse ctx.plugin else plugin orelse return error.Invalid;

    if (owner.len == 0) {
        return error.Invalid;
    }

    const collection = registry.internal_collection(ctx, owner, kind) orelse {
        return error.NotFound;
    };
    const scope: Scope = .{
        .plugin = owner,
        .app = if (collection.shared) "" else if (running) ctx.app else app orelse ctx.app,
        .kind = kind,
    };

    return .{
        .scope = scope,
        .collection = collection,
    };
}

/// Whether the plugin running reaches another plugin's collection: reading through
/// `records.read` with `.internal`, or a `records.read` or `records.write` naming it
/// (`<plugin>.<kind>`); writing only through a `records.write` naming it.
pub fn reaches_other(ctx: *Ctx, owner: []const u8, kind: []const u8, writes: bool) Error!bool {
    std.debug.assert(owner.len > 0);
    std.debug.assert(kind.len > 0);

    const access = switch (ctx.caller) {
        .plugin => |caller| caller.access,
        else => registry.SDK.compiled_access(ctx.plugin),
    } orelse return false;
    const name = std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ owner, kind }) catch {
        return error.OutOfMemory;
    };
    const write = access.held_of("records.write");
    const named_write = if (write) |held| model.permission.contains(held.records, name) else false;

    if (writes) {
        return named_write;
    }

    const read = access.held_of("records.read") orelse return named_write;
    const wide = read.records.len == 0 and read.internal;

    return named_write or wide or model.permission.contains(read.records, name);
}

fn object_of(ctx: *Ctx, text: []const u8) Error!Value {
    std.debug.assert(ctx.now_ms >= 0);

    if (text.len == 0 or text.len > model.internal_record.document_bytes_max) {
        return error.Invalid;
    }

    const parsed = std.json.parseFromSliceLeaky(Value, ctx.arena, text, .{}) catch {
        return error.Invalid;
    };

    if (parsed != .object) {
        return error.Invalid;
    }

    return parsed;
}

/// What the record is found by: each indexed field it holds as text, an integer or a flag.
fn index(
    ctx: *Ctx,
    scope: Scope,
    collection: Collection,
    id: []const u8,
    document: Value,
) Error!void {
    std.debug.assert(document == .object);
    std.debug.assert(collection.indexed.len <= model.internal_record.indexed_max);

    const before = try store.internal_record_values.values_of(ctx.db, ctx.arena, id);

    var values: [model.internal_record.indexed_max]store.internal_record_values.Value = undefined;
    var count: u32 = 0;

    for (collection.indexed) |field| {
        const value = document.object.get(field) orelse continue;
        const text = try model.internal_record.indexed_text(ctx.arena, value) orelse continue;

        values[count] = .{
            .field = field,
            .value = text,
        };
        count += 1;
    }

    try store.internal_record_values.replace(ctx.db, id, values[0..count]);
    raised_matched(ctx, scope, before, values[0..count]);
}

fn match_of(collection: Collection, field: []const u8, value: []const u8) Error!records.Match {
    std.debug.assert(collection.kind.len > 0);

    if (field.len == 0 or !model.internal_record.indexes(collection, field)) {
        return error.Invalid;
    }

    if (value.len > model.internal_record.value_len_max) {
        return error.Invalid;
    }

    return .{
        .field = field,
        .value = value,
    };
}

/// A record as the caller reads it: a field it may not read (`.visibility`) left out.
fn item_of(ctx: *const Ctx, collection: Collection, row: records.Row) Error!Item {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.version > 0);

    var document = row.document;
    const visibility = @import("document/visibility.zig");

    if (visibility.any_hidden(collection.rules)) {
        const text = row.document;
        var parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, text, .{}) catch {
            return error.Invalid;
        };

        visibility.strip(ctx, collection.rules, &parsed);
        document = std.json.Stringify.valueAlloc(ctx.arena, parsed, .{}) catch {
            return error.OutOfMemory;
        };
    }

    return .{
        .id = row.id,
        .version = row.version,
        .document = .{
            .text = document,
        },
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

const Host = @import("../server/sandboxed_plugins.zig").Host;
const plugin_operations = @import("plugin.zig");
const SDK = registry.SDK;

/// A project with greeter installed (its `visit` collection, found by `name`): for tests.
pub const TestProject = Project;

/// A project with greeter installed (its `visit` collection, found by `name`).
const Project = struct {
    harness: sdk.testing.Harness,
    temporary: std.testing.TmpDir,
    host: Host,

    pub fn init(project: *Project) !void {
        std.debug.assert(@embedFile("sandboxed_plugin_greeter").len > 0);

        try project.harness.init();
        errdefer project.harness.deinit();

        project.temporary = std.testing.tmpDir(.{});
        errdefer project.temporary.cleanup();

        try project.temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "greeter.wasm",
            .data = @embedFile("sandboxed_plugin_greeter"),
        });

        const root = ".zig-cache/tmp/" ++ project.temporary.sub_path;
        const arena = project.harness.fixed.allocator();
        const path = try std.fmt.allocPrint(arena, "{s}/greeter.wasm", .{root});
        const dir = try std.fmt.allocPrint(arena, "{s}/plugins", .{root});

        try project.host.init(std.testing.allocator, std.testing.io, dir);

        var system = project.ctx(.system);

        try SDK.bootstrap(&system);

        const added = try SDK.dispatch(&system, plugin_operations.Add, .{
            .file = path,
        });

        _ = try SDK.dispatch(&system, plugin_operations.Enable, .{
            .names = &.{added.name},
        });
    }

    pub fn deinit(project: *Project) void {
        std.debug.assert(project.temporary.sub_path.len > 0);

        project.host.deinit();
        project.temporary.cleanup();
        project.harness.deinit();
    }

    pub fn ctx(project: *Project, who: sdk.Caller) Ctx {
        var made = project.harness.ctx(who);

        std.debug.assert(made.sandboxed_plugins == null);

        made.sandboxed_plugins = project.host.sandboxed_plugins();
        made.now_ms = 1_700_000_000_000;

        return made;
    }
};

test "internal records: a plugin's own, in its app, found by an indexed field" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    var greeter = project.ctx(.anonymous);
    greeter.plugin = "greeter";

    const first = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Ada\",\"count\":1}",
        },
    });
    _ = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Bob\"}",
        },
    });

    var in_shop = greeter;
    in_shop.app = "shop";
    _ = try SDK.dispatch(&in_shop, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Ada\"}",
        },
    });

    const found = (try SDK.dispatch(&greeter, FindOne, .{
        .kind = "visit",
        .field = "name",
        .value = "Ada",
    })).record.?;
    try std.testing.expectEqualStrings(first.id, found.id);

    const saved = try SDK.dispatch(&greeter, Save, .{
        .kind = "visit",
        .id = first.id,
        .document = .{
            .text = "{\"count\":2}",
        },
        .expected_version = 1,
    });
    try std.testing.expectEqual(@as(i64, 2), saved.version);

    const got = try SDK.dispatch(&greeter, Get, .{
        .kind = "visit",
        .id = first.id,
    });
    try std.testing.expect(std.mem.indexOf(u8, got.document.text, "\"Ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.document.text, "\"count\":2") != null);

    const stale = SDK.dispatch(&greeter, Save, .{
        .kind = "visit",
        .id = first.id,
        .document = .{
            .text = "{\"count\":3}",
        },
        .expected_version = 1,
    });
    try std.testing.expectError(error.Conflict, stale);

    const here = try SDK.dispatch(&greeter, Find, .{
        .kind = "visit",
    });
    const there = try SDK.dispatch(&in_shop, Find, .{
        .kind = "visit",
    });
    try std.testing.expectEqual(@as(usize, 2), here.records.len);
    try std.testing.expectEqual(@as(usize, 1), there.records.len);

    const unindexed = SDK.dispatch(&greeter, Find, .{
        .kind = "visit",
        .field = "count",
        .value = "2",
    });
    try std.testing.expectError(error.Invalid, unindexed);

    // The oldest first, only the fields asked for, and how many without reading any.
    const oldest = try SDK.dispatch(&greeter, Find, .{
        .kind = "visit",
        .limit = 1,
        .oldest = true,
        .fields = &.{"name"},
    });
    try std.testing.expectEqualStrings(first.id, oldest.records[0].id);
    try std.testing.expectEqualStrings("{\"name\":\"Ada\"}", oldest.records[0].document.text);

    const counted = try SDK.dispatch(&greeter, Count, .{
        .kind = "visit",
    });
    try std.testing.expectEqual(@as(u64, 2), counted.count);

    const counted_by = try SDK.dispatch(&greeter, Count, .{
        .kind = "visit",
        .field = "name",
        .value = "Bob",
    });
    try std.testing.expectEqual(@as(u64, 1), counted_by.count);
    try std.testing.expectError(error.Invalid, SDK.dispatch(&greeter, Count, .{
        .kind = "visit",
        .field = "count",
        .value = "2",
    }));

    const deleted = try SDK.dispatch(&greeter, Delete, .{
        .kind = "visit",
        .id = first.id,
    });
    try std.testing.expect(deleted.deleted);

    const gone = SDK.dispatch(&greeter, Get, .{
        .kind = "visit",
        .id = first.id,
    });
    try std.testing.expectError(error.NotFound, gone);
}

test "internal records: a save empties the fields it is told to clear, and keeps the rest" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    var greeter = project.ctx(.anonymous);
    greeter.plugin = "greeter";

    const made = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Ada\",\"count\":4}",
        },
    });

    _ = try SDK.dispatch(&greeter, Save, .{
        .kind = "visit",
        .id = made.id,
        .document = .{
            .text = "{}",
        },
        .clear = &.{ "count", "never_there" },
    });

    const got = try SDK.dispatch(&greeter, Get, .{
        .kind = "visit",
        .id = made.id,
    });

    try std.testing.expect(std.mem.indexOf(u8, got.document.text, "\"Ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.document.text, "count") == null);

    const names: [clear_max + 1][]const u8 = @splat("name");

    try std.testing.expectError(error.Invalid, SDK.dispatch(&greeter, Save, .{
        .kind = "visit",
        .id = made.id,
        .document = .{
            .text = "{}",
        },
        .clear = &names,
    }));
}

test "internal records: nobody else's, and with no plugin running only for those who may" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    var greeter = project.ctx(.anonymous);
    greeter.plugin = "greeter";
    _ = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Ada\"}",
        },
    });

    const named_other = SDK.dispatch(&greeter, Find, .{
        .kind = "visit",
        .plugin = "sampler",
    });
    try std.testing.expectError(error.Denied, named_other);

    var stranger = project.ctx(.anonymous);
    stranger.plugin = "farewell";
    const undeclared = SDK.dispatch(&stranger, Find, .{
        .kind = "visit",
    });
    try std.testing.expectError(error.NotFound, undeclared);

    const unknown_kind = SDK.dispatch(&greeter, Find, .{
        .kind = "nope",
    });
    try std.testing.expectError(error.NotFound, unknown_kind);

    var visitor = project.ctx(.anonymous);
    const anonymous = SDK.dispatch(&visitor, Find, .{
        .kind = "visit",
        .plugin = "greeter",
    });
    try std.testing.expectError(error.Denied, anonymous);

    var operator = project.ctx(.system);
    const seen = try SDK.dispatch(&operator, Find, .{
        .kind = "visit",
        .plugin = "greeter",
    });
    try std.testing.expectEqual(@as(usize, 1), seen.records.len);

    const unnamed = SDK.dispatch(&operator, Find, .{
        .kind = "visit",
    });
    try std.testing.expectError(error.Invalid, unnamed);
}

test "internal records in GROQ: the plugin's own, in its app, and nobody else's" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    const Query = @import("record.zig").Query;

    var greeter = project.ctx(.anonymous);
    greeter.plugin = "greeter";
    _ = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Ada\",\"count\":1}",
        },
    });
    _ = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Bob\",\"count\":2}",
        },
    });

    var in_shop = greeter;
    in_shop.app = "shop";
    _ = try SDK.dispatch(&in_shop, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Ada\"}",
        },
    });

    const named = try SDK.dispatch(&greeter, Query, .{
        .query = "*[_type == \"greeter.visit\" && name == $name]{ name, count }",
        .params = .{
            .text = "{\"name\":\"Ada\"}",
        },
    });
    try std.testing.expectEqualStrings("[{\"name\":\"Ada\",\"count\":1}]", named.result.text);

    const counted = try SDK.dispatch(&greeter, Query, .{
        .query = "*[_type == \"greeter.visit\" && count > 1] | order(_createdAt desc).name",
    });
    try std.testing.expectEqualStrings("[\"Bob\"]", counted.result.text);

    const every = try SDK.dispatch(&greeter, Query, .{
        .query = "count(*[_type == \"greeter.visit\"])",
    });
    try std.testing.expectEqualStrings("2", every.result.text);

    var stranger = project.ctx(.anonymous);
    stranger.plugin = "farewell";
    const other = SDK.dispatch(&stranger, Query, .{
        .query = "*[_type == \"greeter.visit\"]",
    });
    try std.testing.expectError(error.Denied, other);

    var operator = project.ctx(.system);
    const person = SDK.dispatch(&operator, Query, .{
        .query = "*[_type == \"greeter.visit\"]",
    });
    try std.testing.expectError(error.Denied, person);
}

test "references in an installed plugin: the relay reads the record before it runs" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    var system = project.ctx(.system);
    const fixture = @import("record/fixture.zig");
    const created = try fixture.published(
        &system,
        "greeter.salutation",
        "{\"note\":\"From the sandbox\"}",
    );
    const asked = try std.fmt.allocPrint(system.arena, "{{\"salutation\":\"{s}\"}}", .{
        created.id,
    });
    const answer = try SDK.call_json(&system, "greeter.recall", asked);

    try std.testing.expect(std.mem.indexOf(u8, answer, "From the sandbox") != null);

    const unknown = SDK.call_json(&system, "greeter.recall", "{\"salutation\":\"nope\"}");
    try std.testing.expectError(error.NotFound, unknown);
}

const Named = sdk.testing.reads.Named;

fn raised_since(ctx: *Ctx, after: u64) !@import("../lib/deps.zig").Index.Changes {
    std.debug.assert(ctx.db.transaction_depth == 0);

    const deps = @import("../lib/deps.zig");
    var changes_index: deps.Index = .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };

    return changes_index.changes_since(ctx.arena, after);
}

fn has_key(keys: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    for (keys) |each| {
        if (std.mem.eql(u8, each, key)) {
            return true;
        }
    }

    return false;
}

test "internal records: a write raises its keys, and a page's read names them" {
    var project: Project = undefined;
    try project.init();
    defer project.deinit();

    var greeter = project.ctx(.anonymous);
    greeter.plugin = "greeter";

    const start = (try raised_since(&greeter, 0)).revision;
    const made = try SDK.dispatch(&greeter, Create, .{
        .kind = "visit",
        .document = .{
            .text = "{\"name\":\"Ada\"}",
        },
    });
    const record_key = try std.fmt.allocPrint(greeter.arena, "internal:greeter/visit/{s}", .{
        made.id,
    });
    const created = try raised_since(&greeter, start);

    try std.testing.expect(has_key(created.keys, record_key));
    try std.testing.expect(has_key(created.keys, "internal:greeter/visit"));

    _ = try SDK.dispatch(&greeter, Save, .{
        .kind = "visit",
        .id = made.id,
        .document = .{
            .text = "{\"count\":2}",
        },
    });
    try std.testing.expect((try raised_since(&greeter, created.revision)).revision >
        created.revision);

    // Drawing a page: the record read names itself and whatever takes the collection away;
    // a lookup names the collection.
    var named: Named = .{};
    var drawing = greeter;
    drawing.reads = named.reads();

    _ = try SDK.dispatch(&drawing, Get, .{
        .kind = "visit",
        .id = made.id,
    });
    _ = try SDK.dispatch(&drawing, Find, .{
        .kind = "visit",
    });

    try std.testing.expect(named.has(record_key));
    try std.testing.expect(named.has("internal:greeter/visit/*"));
    try std.testing.expect(named.has("internal:greeter/visit"));

    // Outside a drawing nothing is named.
    const before = named.count;
    _ = try SDK.dispatch(&greeter, Get, .{
        .kind = "visit",
        .id = made.id,
    });
    try std.testing.expectEqual(before, named.count);

    const saved = (try raised_since(&greeter, 0)).revision;

    _ = try SDK.dispatch(&greeter, Delete, .{
        .kind = "visit",
        .id = made.id,
    });
    try std.testing.expect(has_key((try raised_since(&greeter, saved)).keys, record_key));
}

/// The computed values of records a call wrote many of, worked out together after them, a
/// few at a time: one call to their plugin for every few records, not one each.
fn written_together(
    ctx: *Ctx,
    plugin: ?[]const u8,
    app: ?[]const u8,
    kind: []const u8,
    ids: []const []const u8,
) Error!void {
    std.debug.assert(kind.len > 0);
    std.debug.assert(ids.len <= many_max);

    const target = try scope_of(ctx, plugin, app, kind, true);

    if (target.collection.computed.len == 0 or ids.len == 0) {
        return;
    }

    const rows = try records_named(ctx, target.scope, ids);

    try computed.written_many(ctx, target.scope, target.collection, rows);
}
