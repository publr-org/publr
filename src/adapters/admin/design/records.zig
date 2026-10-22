//! The design's override records of one app, read and written as whoever is signed in:
//! each found by the name it overrides (a route's file, a part's or a pattern's name),
//! saved as published, removed into the trash.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const record_operations = @import("../../../operations/record.zig");
const design = @import("../../../model/design.zig");
const json = @import("../../../lib/json.zig");

const Session = admin.Session;

/// What an override record holds, every type's fields together.
pub const Document = struct {
    route: []const u8 = "",
    name: []const u8 = "",
    label: []const u8 = "",
    category: []const u8 = "",
    description: []const u8 = "",
    html: []const u8 = "",
    output: []const u8 = "",
    variants: []const Variant = &.{},
    default_variant: []const u8 = "",
    default_color_context: []const u8 = "",
    disabled_color_contexts: []const []const u8 = &.{},
};

pub const Variant = design.pattern_settings.Variant;

pub const Override = struct {
    id: []const u8,
    version: i64,
    status: []const u8,
    document: Document,

    /// The name it overrides: a template's route, a part's or a pattern's name.
    pub fn key(override: Override) []const u8 {
        std.debug.assert(override.id.len > 0);

        return if (override.document.route.len > 0)
            override.document.route
        else
            override.document.name;
    }
};

/// The field a type's records are found by.
pub fn key_field(handle: []const u8) []const u8 {
    std.debug.assert(design.is_design(handle));

    return if (std.mem.eql(u8, handle, design.template_handle)) "route" else "name";
}

/// The app's records of the type that are not in the trash, newest first; the one for
/// `name` alone when given. Read a page at a time, each page's documents let go once
/// parsed into the arena.
pub fn list(
    session: *Session,
    handle: []const u8,
    app_name: []const u8,
    name: ?[]const u8,
) ![]const Override {
    std.debug.assert(design.is_design(handle));
    std.debug.assert(app_name.len > 0);

    const Collect = struct {
        out: std.ArrayList(Override) = .empty,

        fn visit(collect: *@This(), inner: *Session, override: Override) !void {
            std.debug.assert(override.id.len > 0);

            try collect.out.append(inner.arena, override);
        }
    };
    var collect: Collect = .{};

    try each(session, handle, app_name, name, &collect, Collect.visit);

    return collect.out.items;
}

/// The names the app's records of the type override, without their documents kept.
pub fn keys(session: *Session, handle: []const u8, app_name: []const u8) ![]const []const u8 {
    std.debug.assert(design.is_design(handle));
    std.debug.assert(app_name.len > 0);

    const Collect = struct {
        out: std.ArrayList([]const u8) = .empty,

        fn visit(collect: *@This(), inner: *Session, override: Override) !void {
            std.debug.assert(override.id.len > 0);

            try collect.out.append(inner.arena, override.key());
        }
    };
    var collect: Collect = .{};

    try each(session, handle, app_name, null, &collect, Collect.visit);

    return collect.out.items;
}

const page: u32 = 50;

/// Each of the app's records of the type, parsed into the arena (its strings copied, so
/// the page read can be let go), handed to `visit`.
fn each(
    session: *Session,
    handle: []const u8,
    app_name: []const u8,
    name: ?[]const u8,
    visitor: anytype,
    comptime visit: fn (@TypeOf(visitor), *Session, Override) anyerror!void,
) !void {
    std.debug.assert(design.is_design(handle));
    std.debug.assert(app_name.len > 0);

    const arena = session.arena;
    const app_clause = try std.fmt.allocPrint(arena, "app:is:{s}", .{app_name});
    const filters = [_][]const u8{ "status:not:trashed", app_clause };
    const scratch = try session.ctx.scratch();
    var offset: u32 = 0;

    while (true) {
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        // The page's rows and documents go to the scratch; what is kept, to the arena.
        var paged = session.ctx;

        paged.arena = scratch.allocator();

        const listed = try registry.SDK.dispatch(&paged, record_operations.List, .{
            .type = handle,
            .filters = &filters,
            .filter_field = if (name != null) key_field(handle) else null,
            .filter_value = name,
            .limit = page,
            .offset = offset,
            .documents = true,
            .purpose = .edit,
        });

        for (listed.records, listed.documents) |record, text| {
            const parsed = json.parse(Document, arena, text, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            });
            const document = parsed catch continue;

            try visit(visitor, session, .{
                .id = try arena.dupe(u8, record.id),
                .version = record.version,
                .status = try arena.dupe(u8, record.status),
                .document = document,
            });
        }

        if (listed.records.len < page) {
            return;
        }

        offset += page;
    }
}

/// The override saved and published: the app's record for the name written over, else a
/// new one made in the app.
pub fn save(session: *Session, handle: []const u8, app_name: []const u8, document: Document) !void {
    std.debug.assert(design.is_design(handle));
    std.debug.assert(app_name.len > 0);

    const arena = session.arena;
    const text = try json_of(arena, handle, document);
    const templated = std.mem.eql(u8, handle, design.template_handle);
    const key = if (templated) document.route else document.name;
    const existing = try list(session, handle, app_name, key);

    if (existing.len > 0) {
        const saved = try registry.SDK.dispatch(&session.ctx, record_operations.Save, .{
            .id = existing[0].id,
            .document = text,
            .expected_version = existing[0].version,
        });

        if (saved.changed) {
            _ = try registry.SDK.dispatch(&session.ctx, record_operations.Publish, .{
                .id = existing[0].id,
            });
        }

        return;
    }

    const created = try registry.SDK.dispatch(&session.ctx, record_operations.Create, .{
        .type = handle,
        .document = text,
        .app = app_name,
    });

    _ = try registry.SDK.dispatch(&session.ctx, record_operations.Publish, .{
        .id = created.id,
    });
}

/// Every record of the app overriding `name` moved to the trash: the file shows again.
pub fn remove(session: *Session, handle: []const u8, app_name: []const u8, name: []const u8) !u32 {
    std.debug.assert(design.is_design(handle));
    std.debug.assert(name.len > 0);

    const existing = try list(session, handle, app_name, name);

    for (existing) |override| {
        _ = try registry.SDK.dispatch(&session.ctx, record_operations.Delete, .{
            .id = override.id,
            .expected_version = override.version,
        });
    }

    return @intCast(existing.len);
}

/// The document a type's record takes: its own fields only.
fn json_of(arena: std.mem.Allocator, handle: []const u8, document: Document) ![]const u8 {
    std.debug.assert(design.is_design(handle));
    std.debug.assert(document.html.len <= 4 << 20);

    const options: std.json.Stringify.Options = .{};

    if (std.mem.eql(u8, handle, design.template_handle)) {
        const fields = .{
            .route = document.route,
            .html = document.html,
            .output = document.output,
        };

        return std.json.Stringify.valueAlloc(arena, fields, options);
    }

    if (std.mem.eql(u8, handle, design.part_handle)) {
        const fields = .{
            .name = document.name,
            .label = document.label,
            .html = document.html,
            .output = document.output,
        };

        return std.json.Stringify.valueAlloc(arena, fields, options);
    }

    std.debug.assert(document.variants.len <= design.pattern_settings.variants_max);

    const fields = .{
        .name = document.name,
        .label = document.label,
        .category = document.category,
        .description = document.description,
        .html = document.html,
        .variants = document.variants,
        .default_variant = document.default_variant,
        .default_color_context = document.default_color_context,
        .disabled_color_contexts = document.disabled_color_contexts,
    };

    return std.json.Stringify.valueAlloc(arena, fields, options);
}

test "json_of: a pattern keeps its variants and color settings as fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const variants = [_]Variant{
        .{
            .name = "light",
            .label = "Light",
            .html = "<p>a</p>",
        },
        .{
            .name = "dark",
            .label = "Dark",
            .description = "On dark",
            .html = "<p>b</p>",
        },
    };
    const disabled = [_][]const u8{"slate"};
    const text = try json_of(arena, design.pattern_handle, .{
        .name = "hero",
        .html = "<p>a</p>",
        .variants = &variants,
        .default_variant = "dark",
        .default_color_context = "terracotta",
        .disabled_color_contexts = &disabled,
    });
    const read = try json.parse(Document, arena, text, .{
        .ignore_unknown_fields = true,
    });

    try std.testing.expectEqual(@as(usize, 2), read.variants.len);
    try std.testing.expectEqualStrings("On dark", read.variants[1].description);
    try std.testing.expectEqualStrings("dark", read.default_variant);
    try std.testing.expectEqualStrings("terracotta", read.default_color_context);
    try std.testing.expectEqualStrings("slate", read.disabled_color_contexts[0]);

    const part = try json_of(arena, design.part_handle, .{
        .name = "header",
        .html = "<p>h</p>",
    });

    try std.testing.expect(std.mem.indexOf(u8, part, "variants") == null);
}
