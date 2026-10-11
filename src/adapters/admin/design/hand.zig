//! What the block editor needs on a visual record's page, as JSON for two attributes:
//! `data-editor-templates`, the template the record's route is drawn in, the page around
//! it (its layout, the template's place marked) and the parts they may place (each the
//! override's editing HTML, else the file's own render), and
//! `data-editor-patterns`, the app's patterns (its files, overridden or added to by records).
const std = @import("std");
const admin = @import("../../admin.zig");
const design = @import("../../../model/design.zig");
const engine = @import("../../../template.zig");
const files = @import("files.zig");
const records = @import("records.zig");
const override = @import("override.zig");
const patterns = @import("hand/patterns.zig");
const App = @import("../../apps/state.zig").App;

const Session = admin.Session;
const regions = engine.regions;
const Writer = std.Io.Writer;

pub const Handed = struct {
    templates: []const u8 = "",
    patterns: []const u8 = "",
};

/// The record whose page the editor fills.
pub const Record = struct {
    handle: []const u8,
    app: ?[]const u8,
    slug: ?[]const u8,
    /// The editor's heading: the record's title, `New post` for a new one.
    title: []const u8,
    /// Empty for a new record.
    id: []const u8 = "",
    /// The record's own title, empty for a new one, and the document the editor shows (its
    /// edit copy, a new one's defaults): what the route's page reads with none published.
    entry_title: []const u8 = "",
    document: ?std.json.Value = null,
};

pub fn of(session: *Session, record: Record) !Handed {
    std.debug.assert(session.signed_in());
    std.debug.assert(record.handle.len > 0);

    const app = app_for(session, record) orelse return .{};

    return .{
        .templates = try templates_json(session, app, record),
        .patterns = try patterns_json(session, app),
    };
}

/// The record's app, else the one the admin means, else the first whose pages show the type.
fn app_for(session: *const Session, record: Record) ?*const App {
    std.debug.assert(session.signed_in());
    std.debug.assert(record.handle.len > 0);

    if (files.app_of(session, record.app)) |app| {
        return app;
    }

    for (session.project.apps) |*app| {
        if (files.route_of(app, record.handle) != null) {
            return app;
        }
    }

    return null;
}

const Source = struct {
    label: []const u8,
    html: []const u8,
    overridden: bool,
};

fn templates_json(session: *Session, app: *const App, record: Record) ![]const u8 {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(record.handle.len > 0);

    const arena = session.arena;
    const route = files.route_of(app, record.handle);
    const page = if (route) |found|
        try files.rendered(session, app, found, .{
            .handle = record.handle,
            .slug = record.slug,
            .id = record.id,
            .title = record.entry_title,
            .document = record.document,
        })
    else
        null;
    var out: Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{
        .writer = &out.writer,
    };

    try json.beginObject();
    try json.objectField("template");

    if (try template_of(session, app, route, page)) |source| {
        try json.write(source);
    } else {
        try json.write(null);
    }

    try json.objectField("frame");
    try json.write(try frame_of(session.arena, page));
    try json.objectField("parts");
    try write_parts(session, &json, app, page);
    try json.objectField("saveUrl");
    try json.write(try save_url(session, app));
    try json.objectField("title");
    try json.write(record.title);
    try json.endObject();

    return out.written();
}

/// Where the editor saves: the override endpoint, naming the app.
pub fn save_url(session: *const Session, app: *const App) ![]const u8 {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(override.path.len > 0);

    const base = session.project.admin_path();

    return std.fmt.allocPrint(session.arena, "{s}{s}?app={s}", .{
        base,
        override.path,
        app.spec.name,
    });
}

/// The route's template: its override's editing HTML, else the file's region as rendered,
/// its slots and parts emptied. Null for a route without a region, or no route.
pub fn template_of(
    session: *Session,
    app: *const App,
    route: ?*const engine.Route,
    page: ?[]const u8,
) !?Source {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(session.signed_in());

    const found = route orelse return null;
    const template = &app.pages().templates[found.template];

    if (!files.marks_region(template)) {
        return null;
    }

    const saved = try records.list(session, design.template_handle, app.spec.name, template.rel);

    if (saved.len > 0 and saved[0].document.html.len > 0) {
        return .{
            .label = template.rel,
            .html = saved[0].document.html,
            .overridden = true,
        };
    }

    const html = page orelse return .{
        .label = template.rel,
        .html = "",
        .overridden = false,
    };
    const region = regions.find(html, whole(html), regions.template_attribute, null) orelse
        return .{
            .label = template.rel,
            .html = "",
            .overridden = false,
        };

    return .{
        .label = template.rel,
        .html = try emptied(session.arena, html, region.inner),
        .overridden = false,
    };
}

/// The marker the editor puts the template in, in the page around it.
const frame_marker = "<div data-publr-template-frame></div>";

/// The page's body around the route's template (the layout: a header and a footer part,
/// say), the template's place marked and every part emptied. Empty without a region.
fn frame_of(arena: std.mem.Allocator, page: ?[]const u8) ![]const u8 {
    const html = page orelse return "";
    std.debug.assert(html.len < 1 << 31);

    const attribute = regions.template_attribute;
    const region = regions.find(html, whole(html), attribute, null) orelse return "";
    const body_open = std.mem.indexOf(u8, html, "<body") orelse return "";
    const body_start = (std.mem.indexOfScalarPos(u8, html, body_open, '>') orelse return "") + 1;
    const body_end = std.mem.lastIndexOf(u8, html, "</body>") orelse html.len;

    if (body_start > region.open.start or region.close.end > body_end) {
        return "";
    }

    var out: Writer.Allocating = .init(arena);
    const before: regions.Range = .{
        .start = @intCast(body_start),
        .end = region.open.start,
    };
    const after: regions.Range = .{
        .start = region.close.end,
        .end = @intCast(body_end),
    };

    try out.writer.writeAll(try emptied(arena, html, before));
    try out.writer.writeAll(frame_marker);
    try out.writer.writeAll(try emptied(arena, html, after));

    return out.written();
}

fn whole(text: []const u8) regions.Range {
    std.debug.assert(text.len < 1 << 31);

    return .{
        .start = 0,
        .end = @intCast(text.len),
    };
}

/// The HTML in `range`, every slot's and part's inside left out: the editor draws those
/// from the document and the parts' own sources.
fn emptied(arena: std.mem.Allocator, html: []const u8, range: regions.Range) ![]const u8 {
    std.debug.assert(range.end <= html.len);
    std.debug.assert(range.start <= range.end);

    var buffer: [regions.named_max]regions.Named = undefined;
    const attributes = [_][]const u8{ regions.slot_attribute, regions.part_attribute };
    const markers = regions.list(html, range, &attributes, &buffer);
    var out: Writer.Allocating = .init(arena);
    var at = range.start;

    for (markers) |marker| {
        try out.writer.writeAll(html[at..marker.region.inner.start]);
        at = marker.region.inner.end;
    }

    try out.writer.writeAll(html[at..range.end]);

    return out.written();
}

/// Every part the app's files place: its override's editing HTML, else what the file
/// renders inside it on the record's page.
pub fn write_parts(
    session: *Session,
    json: *std.json.Stringify,
    app: *const App,
    page: ?[]const u8,
) !void {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(session.signed_in());

    const names = try files.part_names(session.arena, app);
    const saved = try records.list(session, design.part_handle, app.spec.name, null);

    try json.beginObject();

    for (names) |name| {
        var source: Source = .{
            .label = name,
            .html = "",
            .overridden = false,
        };

        for (saved) |part| {
            if (std.mem.eql(u8, part.document.name, name)) {
                source.html = part.document.html;
                source.overridden = true;

                if (part.document.label.len > 0) {
                    source.label = part.document.label;
                }

                break;
            }
        }

        if (!source.overridden) {
            if (page) |html| {
                const found = regions.find(html, whole(html), regions.part_attribute, name);

                source.html = if (found) |region| region.inner.of(html) else "";
            }
        }

        try json.objectField(name);
        try json.write(source);
    }

    try json.endObject();
}

pub const Pattern = patterns.Pattern;
pub const patterns_of = patterns.patterns_of;
pub const patterns_json = patterns.patterns_json;

test "frame_of: the body around the template, its place marked, the parts emptied" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const page =
        \\<html><body class="b"><header data-publr-template-part="header"><p>H</p></header>
        \\<main data-publr-template><h1 data-publr-slot="title">T</h1></main>
        \\<footer data-publr-template-part="footer"><p>F</p></footer></body></html>
    ;
    const frame = try frame_of(arena_state.allocator(), page);

    try std.testing.expectEqualStrings(
        \\<header data-publr-template-part="header"></header>
        \\<div data-publr-template-frame></div>
        \\<footer data-publr-template-part="footer"></footer>
    , frame);
    const bare = try frame_of(arena_state.allocator(), "<p>no region</p>");
    try std.testing.expectEqualStrings("", bare);
}

test {
    _ = patterns;
}
