//! The Website singleton: the fields the theme's homepage renders, read as the entry of `/`.
//! No reference to a page: every page has page fields, the homepage has these.
const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const registry = @import("../app/registry.zig");
const types = @import("content_type.zig");
const records = @import("record.zig");
const declared = @import("../sdk/plugin/types.zig");

pub const handle = "website";
pub const dependency_key = "type:" ++ handle;
const Field = model.field.Def;

fn line(name: []const u8, label: []const u8) Field {
    std.debug.assert(name.len > 0);
    std.debug.assert(label.len > 0);
    return .{ .name = name, .label = label, .kind = "string" };
}

fn paragraph(name: []const u8, label: []const u8) Field {
    std.debug.assert(name.len > 0);
    std.debug.assert(label.len > 0);
    return .{ .name = name, .label = label, .kind = "text" };
}

fn address(name: []const u8, label: []const u8) Field {
    std.debug.assert(name.len > 0);
    std.debug.assert(label.len > 0);
    return .{ .name = name, .label = label, .kind = "string", .help = "A path or a full URL" };
}

fn media(name: []const u8, label: []const u8) Field {
    std.debug.assert(name.len > 0);
    std.debug.assert(label.len > 0);
    return .{
        .name = name,
        .label = label,
        .kind = "string",
        .help = "A theme asset path (/theme/assets/...) or a full URL",
    };
}

pub const definition: model.content_type.Def = .{
    .handle = handle,
    .name = "Website",
    .description = "What the homepage says: every section, in order, top to bottom.",
    .kind = .settings,
    .title_field = "",
    .fields = &.{
        line("hero_pill_label", "Hero announcement"),
        address("hero_pill_url", "Hero announcement link"),
        paragraph("hero_title", "Hero title"),
        paragraph("hero_subcopy", "Hero subcopy"),
        line("hero_primary_label", "Hero email button"),
        line("hero_secondary_label", "Hero secondary button"),
        address("hero_secondary_url", "Hero secondary link"),
        line("hero_ai_demo_label", "Hero AI demo button"),
        paragraph("hero_fineprint", "Hero fine print"),
        media("hero_image", "Hero image"),
        line("hero_image_alt", "Hero image alt text"),
        line("hero_rail_label", "Logo rail caption"),
        line("scale_eyebrow", "Scale eyebrow"),
        paragraph("scale_title", "Scale title"),
        paragraph("scale_body", "Scale body"),
        media("scale_video", "Scale video"),
        paragraph("stories_title", "Customer stories title"),
        .{ .name = "stories", .label = "Customer stories", .kind = "repeater", .fields = &.{
            media("photo", "Photo"),
            line("photo_alt", "Photo alt text"),
            media("logo", "Logo"),
            line("logo_alt", "Logo alt text"),
            paragraph("quote", "Quote"),
            line("name", "Name"),
            line("position", "Position"),
            address("url", "Link"),
        } },
        paragraph("products_title", "Products title"),
        line("products_cta_label", "Products button"),
        address("products_cta_url", "Products button link"),
        .{ .name = "products", .label = "Product cards", .kind = "repeater", .fields = &.{
            line("eyebrow", "Eyebrow"),
            line("badge", "Badge"),
            line("title", "Title"),
            paragraph("body", "Body"),
            address("url", "Link"),
            media("image", "Image"),
            line("image_alt", "Image alt text"),
        } },
        paragraph("fees_title", "Fees title"),
        paragraph("fees_body", "Fees body"),
        .{ .name = "fees", .label = "Fee rows", .kind = "repeater", .fields = &.{
            line("label", "Label"),
            line("figure", "Figure"),
            line("footnote_mark", "Footnote mark"),
        } },
        paragraph("fees_disclosure", "Fees disclosure"),
        paragraph("onboarding_title", "Onboarding title"),
        paragraph("onboarding_body", "Onboarding body"),
        media("onboarding_video", "Onboarding video"),
        paragraph("security_title", "Security title"),
        paragraph("security_body", "Security body"),
        line("security_cta_label", "Security button"),
        address("security_cta_url", "Security button link"),
        media("security_video", "Security video"),
        paragraph("testimonials_title", "Testimonials title"),
        .{ .name = "testimonials", .label = "Testimonials", .kind = "repeater", .fields = &.{
            paragraph("quote", "Quote"),
            line("name", "Name"),
            line("handle", "Handle"),
            media("avatar", "Avatar"),
        } },
        paragraph("closing_title", "Closing title"),
        paragraph("closing_body", "Closing body"),
        line("closing_cta_label", "Closing email button"),
        paragraph("closing_fineprint", "Closing fine print"),
    },
};

pub fn ensure(ctx: *sdk.Ctx) sdk.Error!void {
    std.debug.assert(ctx.caller != .anonymous);
    std.debug.assert(definition.fields.len <= model.field.fields_max);
    var system = ctx.*;
    system.caller = .system;
    const existing = try types.find_raw(ctx, handle);

    if (existing) |row| {
        if (!row.def.system or !std.mem.eql(u8, row.def.owner, "publr")) return error.Conflict;
    }

    try declared.apply(&system, &.{.{ .owner = "publr", .def = definition }});
}

pub fn single(ctx: *sdk.Ctx) sdk.Error!?records.Record {
    std.debug.assert(ctx.now_ms >= 0);
    const def = try types.find_raw(ctx, handle) orelse return null;
    const found = try store.records.list(ctx.db, ctx.arena, .{
        .type_ids = &.{def.id},
        .limit = 1,
    });
    return if (found.len > 0) found[0] else null;
}

/// The published singleton and its live document; drafts and pending edits stay private.
pub const Homepage = struct { record: records.Record, document: std.json.Value };

/// Internal delivery read: the site depends on `type:website`, so publishing the settings
/// rebuilds `/` through normal record invalidation.
pub fn homepage(ctx: *sdk.Ctx) !Homepage {
    std.debug.assert(dependency_key.len > 0);
    ctx.depend("", dependency_key);
    const row = try single(ctx) orelse return error.HomepageNotSet;

    if (!registry.Statuses.is_live(row.status)) {
        return error.HomepageNotSet;
    }

    const def = (try types.find_raw(ctx, handle)).?.def;
    const document = try records.document.document_of(ctx, row.id, store.values.live, def);

    std.debug.assert(document == .object);

    return .{ .record = row, .document = document };
}

test "the homepage is the published website singleton and nothing before it" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    try ensure(&system);
    try ensure(&system);
    try std.testing.expectError(error.HomepageNotSet, homepage(&system));
    var editor = harness.ctx(.{ .user = .{ .id = "editor", .role = .editor } });
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&editor, records.Create, .{
        .type = handle,
        .document = "{\"hero_title\":\"Hello\"}",
    }));
    const draft = try registry.SDK.dispatch(&system, records.Create, .{
        .type = handle,
        .document = "{\"hero_title\":\"Hello\",\"fees\":[{\"label\":\"Wires\",\"figure\":\"$0\"}]}",
    });
    try std.testing.expectError(error.HomepageNotSet, homepage(&system));
    _ = try registry.SDK.dispatch(&system, records.Publish, .{ .id = draft.id });
    const live = try homepage(&system);
    try std.testing.expectEqualStrings(draft.id, live.record.id);
    try std.testing.expectEqualStrings("Hello", live.document.object.get("hero_title").?.string);
    const fees = live.document.object.get("fees").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), fees.len);
    try std.testing.expectEqualStrings("$0", fees[0].object.get("figure").?.string);
    _ = try registry.SDK.dispatch(&system, records.Save, .{
        .id = draft.id,
        .document = "{\"hero_title\":\"Pending\"}",
    });
    const unchanged = try homepage(&system);
    const kept = unchanged.document.object.get("hero_title").?.string;
    try std.testing.expectEqualStrings("Hello", kept);
    _ = try registry.SDK.dispatch(&system, records.Publish, .{ .id = draft.id });
    const applied = try homepage(&system);
    const replaced = applied.document.object.get("hero_title").?.string;
    try std.testing.expectEqualStrings("Pending", replaced);
    try std.testing.expect(applied.document.object.get("fees") == null);
}

test "publishing the website settings invalidates the homepage's readers" {
    const deps = @import("../lib/deps.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var system = harness.ctx(.system);
    try ensure(&system);
    var index = try deps.Index.open(system.db, .{ .quiet_ms = deps.quiet_ms });
    try index.record("/", &.{dependency_key});
    try index.record("/unrelated", &.{"unrelated"});
    _ = try registry.SDK.dispatch(&system, records.Create, .{
        .type = handle,
        .document = "{\"hero_title\":\"Hello\"}",
        .status = "published",
    });
    const batch = (try index.take(system.arena, system.now_ms + deps.quiet_ms)).?;
    const affected = try index.plan(system.arena, batch);
    try std.testing.expectEqual(@as(usize, 1), affected.len);
    try std.testing.expectEqualStrings("/", affected[0]);
}
