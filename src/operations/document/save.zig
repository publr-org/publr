//! Saving a document: the fields given, merged over the copy they change. Without a status,
//! a live document's edit parks as its pending copy; with one, it goes straight into the
//! live document (and the pending copy, so publishing that later keeps it), then on to that
//! status.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Record = store.documents.Record;
const Def = store.definitions.Def;
const Value = std.json.Value;

pub const Saved = struct { version: i64, slug: ?[]const u8, changed: bool };

pub fn Of(comptime Domain: type) type {
    return struct {
        const documents = Domain.documents;
        const values = Domain.values;
        const definitions = Domain.definition;
        const document = Domain.document;
        const lifecycle = Domain.lifecycle;
        const load = Domain.access.load;
        const notice_name = Domain.notice_name;
        const title_of = model.document.title_of;

        pub fn save(
            ctx: *Ctx,
            granted: *const Grant,
            id: []const u8,
            text: []const u8,
            expected: ?i64,
            status: ?[]const u8,
        ) Error!Saved {
            std.debug.assert(ctx.db.transaction_depth >= 1);

            if (id.len > 64 << 10) {
                return error.Invalid;
            }

            const row = try load(ctx, id, granted) orelse return error.NotFound;
            const type_row = try definitions.find(ctx, row.type_id) orelse return error.NotFound;
            const given = try fields_of(ctx, text);

            if (status) |to| {
                return save_live(ctx, granted, row, type_row.def, given, expected, to);
            }

            const live = registry.Statuses.is_live(row.status);
            const park = row.changed or live;
            const base = if (row.changed) values.pending else values.live;
            var parsed = try merged(ctx, row, type_row.def, base, given);
            const slug = try checked(ctx, row, type_row.def, &parsed, live);
            const actor = ctx.caller.user_id();
            const slot = if (park) values.pending else values.live;

            if (!park) {
                try document.snapshot_live(ctx, row, type_row.def);
            }

            try write(ctx, row, type_row.def, slot, parsed);

            // An edit taken back leaves nothing to publish: the pending copy that now reads
            // as the live one goes, and the record is not changed any more.
            const unchanged = park and live and try same_as_live(ctx, row.id);
            const kept = park and !unchanged;

            if (unchanged) {
                try values.clear(ctx.db, row.id, values.pending);
            }

            const version = try documents.save(ctx.db, row.id, actor, expected, ctx.now_ms, kept);

            if (!park) {
                ctx.notice(notice_name("saved"), row.id);
            } else if (unchanged) {
                if (row.changed) {
                    ctx.notice(notice_name("changes_discarded"), row.id);
                }
            } else if (!row.changed) {
                ctx.notice(notice_name("changed"), row.id);
            } else {
                ctx.notice(notice_name("changes_saved"), row.id);
            }

            return .{ .version = version, .slug = slug, .changed = kept };
        }

        /// Whether the pending copy holds exactly what the live one does, field by field.
        fn same_as_live(ctx: *Ctx, id: []const u8) Error!bool {
            std.debug.assert(id.len > 0);

            const live = try values.read(ctx.db, ctx.arena, id, values.live);
            const pending = try values.read(ctx.db, ctx.arena, id, values.pending);

            if (live.len != pending.len) {
                return false;
            }

            for (live, pending) |one, other| {
                if (!std.mem.eql(u8, one.field, other.field) or one.ordinal != other.ordinal) {
                    return false;
                }

                if (!std.meta.eql(std.meta.activeTag(one.value), std.meta.activeTag(other.value))) {
                    return false;
                }

                const equal = switch (one.value) {
                    .integer => |number| number == other.value.integer,
                    .real => |number| number == other.value.real,
                    .text => |text| std.mem.eql(u8, text, other.value.text),
                };

                if (!equal) {
                    return false;
                }
            }

            return true;
        }

        /// The fields straight into the live document, and into the pending copy when there
        /// is one; then the move to `to`, unless the record is there already.
        fn save_live(
            ctx: *Ctx,
            granted: *const Grant,
            row: Record,
            def: Def,
            given: Value,
            expected: ?i64,
            to: []const u8,
        ) Error!Saved {
            std.debug.assert(ctx.db.transaction_depth >= 1);
            std.debug.assert(given == .object);

            if (to.len == 0 or to.len > model.status.id_len_max) {
                return error.Invalid;
            }

            try lifecycle.check_move(row, def, to, granted);

            const live = registry.Statuses.is_live(row.status);
            var parsed = try merged(ctx, row, def, values.live, given);
            const slug = try checked(ctx, row, def, &parsed, live);
            const actor = ctx.caller.user_id();
            const changed = row.changed;
            var version = try documents.save(ctx.db, row.id, actor, expected, ctx.now_ms, changed);

            try document.snapshot_live(ctx, row, def);
            try write(ctx, row, def, values.live, parsed);

            if (row.changed) {
                const pending = try merged(ctx, row, def, values.pending, given);

                try write(ctx, row, def, values.pending, pending);
            }

            ctx.notice(notice_name("saved"), row.id);

            if (!std.mem.eql(u8, row.status, to)) {
                version = (try lifecycle.settle(ctx, row, to, granted)).version;
            }

            return .{ .version = version, .slug = slug, .changed = row.changed };
        }

        fn write(ctx: *Ctx, row: Record, def: Def, slot: []const u8, parsed: Value) Error!void {
            std.debug.assert(slot.len > 0);
            std.debug.assert(parsed == .object);

            try values.write(
                registry.Kinds.all,
                ctx.db,
                row.id,
                slot,
                row.type_id,
                def.fields,
                parsed,
            );
        }

        /// The given document, which must be a JSON object: the fields to write.
        fn fields_of(ctx: *Ctx, text: []const u8) Error!Value {
            std.debug.assert(ctx.now_ms >= 0);

            if (text.len == 0 or text.len > documents.document_bytes_max) {
                return error.Invalid;
            }

            const given = std.json.parseFromSliceLeaky(Value, ctx.arena, text, .{}) catch {
                return error.Invalid;
            };

            if (given != .object) {
                return error.Invalid;
            }

            return given;
        }

        /// The copy in `slot`, with the given fields over it, parsed and validated as a whole
        /// document: a field left out keeps its value.
        fn merged(ctx: *Ctx, row: Record, def: Def, slot: []const u8, given: Value) Error!Value {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(given == .object);

            var base = try document.document_of(ctx, row.id, slot, def);

            if (base != .object) {
                return error.Invalid;
            }

            var fields = given.object.iterator();

            while (fields.next()) |field| {
                try base.object.put(ctx.arena, field.key_ptr.*, field.value_ptr.*);
            }

            const text = std.json.Stringify.valueAlloc(ctx.arena, base, .{}) catch {
                return error.OutOfMemory;
            };

            return document.parse_document(ctx, def, text, false);
        }

        /// What every write checks before it lands: the title, a unique slug, taken values,
        /// targets that are not live, and the domain's own rules. The slug, if any.
        fn checked(
            ctx: *Ctx,
            row: Record,
            def: Def,
            parsed: *Value,
            live: bool,
        ) Error!?[]const u8 {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(parsed.* == .object);

            const title = try title_of(def, parsed.*);
            const type_id = row.type_id;
            const slug = try document.unique_slug(ctx, type_id, def, parsed, title, row.id, live);

            try document.refuse_taken_values(ctx, row.type_id, def, parsed.*, row.id);
            try document.refuse_unpublished_targets(ctx, def, parsed.*);
            try Domain.config.check_document(ctx, def, parsed.*);

            return slug;
        }
    };
}

const records = @import("../record.zig");
const SDK = registry.SDK;

fn published_post(ctx: *Ctx, document_text: []const u8) Error![]const u8 {
    std.debug.assert(document_text.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const created = try SDK.dispatch(ctx, records.Create, .{
        .type = "post",
        .document = document_text,
    });

    _ = try SDK.dispatch(ctx, records.Publish, .{ .id = created.id });

    return created.id;
}

test "a save writes only the fields it is given" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try records.fixture.post_type(&system);

    const created = try SDK.dispatch(&system, records.Create, .{
        .type = "post",
        .document = "{\"title\":\"One\",\"body\":\"first\",\"views\":5}",
    });
    _ = try SDK.dispatch(&system, records.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Two\"}",
    });

    const got = try SDK.dispatch(&system, records.Get, .{ .id = created.id, .purpose = .edit });
    try std.testing.expectEqualStrings("Two", got.record.title);
    try std.testing.expect(std.mem.indexOf(u8, got.document, "\"first\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, got.document, "\"views\":5") != null);

    const not_an_object = SDK.dispatch(&system, records.Save, .{
        .id = created.id,
        .document = "[]",
    });
    try std.testing.expectError(error.Invalid, not_an_object);
}

test "a save with the live status writes live and pending, and publishes nothing else" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try records.fixture.post_type(&system);

    var anon = harness.ctx(.anonymous);
    const id = try published_post(&system, "{\"title\":\"One\",\"body\":\"first\",\"views\":1}");

    const parked = try SDK.dispatch(&system, records.Save, .{
        .id = id,
        .document = "{\"title\":\"Draft title\"}",
    });
    try std.testing.expect(parked.changed);

    const live = try SDK.dispatch(&system, records.Save, .{
        .id = id,
        .document = "{\"views\":9}",
        .status = "published",
    });
    try std.testing.expect(live.changed);

    const public_view = try SDK.dispatch(&anon, records.Get, .{ .id = id });
    try std.testing.expectEqualStrings("One", public_view.record.title);
    try std.testing.expect(std.mem.indexOf(u8, public_view.document, "\"views\":9") != null);

    const editing = try SDK.dispatch(&system, records.Get, .{ .id = id, .purpose = .edit });
    try std.testing.expectEqualStrings("Draft title", editing.record.title);
    try std.testing.expect(std.mem.indexOf(u8, editing.document, "\"views\":9") != null);

    _ = try SDK.dispatch(&system, records.Publish, .{ .id = id });

    const after = try SDK.dispatch(&anon, records.Get, .{ .id = id });
    try std.testing.expectEqualStrings("Draft title", after.record.title);
    try std.testing.expect(std.mem.indexOf(u8, after.document, "\"views\":9") != null);
}

test "an edit taken back leaves the record unchanged" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try records.fixture.post_type(&system);

    const id = try published_post(&system, "{\"title\":\"Test\",\"body\":\"first\",\"views\":1}");

    const edited = try SDK.dispatch(&system, records.Save, .{
        .id = id,
        .document = "{\"title\":\"Test111\"}",
    });
    try std.testing.expect(edited.changed);

    const back = try SDK.dispatch(&system, records.Save, .{
        .id = id,
        .document = "{\"title\":\"Test\"}",
    });
    try std.testing.expect(!back.changed);

    const got = try SDK.dispatch(&system, records.Get, .{ .id = id, .purpose = .edit });
    try std.testing.expect(!got.record.changed);
    try std.testing.expectEqualStrings("Test", got.record.title);

    const again = try SDK.dispatch(&system, records.Save, .{
        .id = id,
        .document = "{\"title\":\"Test\"}",
    });
    try std.testing.expect(!again.changed);
}

test "a save with another status moves along a registered transition only" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try records.fixture.post_type(&system);

    var anon = harness.ctx(.anonymous);
    const created = try SDK.dispatch(&system, records.Create, .{
        .type = "post",
        .document = "{\"title\":\"One\"}",
    });
    const stale = SDK.dispatch(&system, records.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Two\"}",
        .expected_version = 99,
        .status = "published",
    });
    try std.testing.expectError(error.Conflict, stale);

    _ = try SDK.dispatch(&system, records.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Two\"}",
        .status = "published",
    });
    const shown = try SDK.dispatch(&anon, records.Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("Two", shown.record.title);
    try std.testing.expectEqualStrings("published", shown.record.status);

    _ = try SDK.dispatch(&system, records.Transition, .{ .id = created.id, .to = "archived" });
    const unregistered = SDK.dispatch(&system, records.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Three\"}",
        .status = "published",
    });
    try std.testing.expectError(error.Invalid, unregistered);

    const unknown = SDK.dispatch(&system, records.Save, .{
        .id = created.id,
        .document = "{\"title\":\"Three\"}",
        .status = "nope",
    });
    try std.testing.expectError(error.Invalid, unknown);
}

test "a save is refused a status its grant does not allow" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);
    try records.fixture.post_type(&system);

    const created = try SDK.dispatch(&system, records.Create, .{
        .type = "post",
        .document = "{\"title\":\"One\"}",
    });
    var drafts_only = Grant.allow_all;
    drafts_only.statuses = &.{"draft"};

    var transaction = try system.db.transaction();
    defer transaction.rollback();

    const denied = records.domain.crud.save(
        &system,
        &drafts_only,
        created.id,
        "{\"title\":\"Two\"}",
        null,
        "published",
    );
    try std.testing.expectError(error.Denied, denied);
}
