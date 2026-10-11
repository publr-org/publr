//! The app's library as the design system builder's page hands it over: its patterns,
//! the templates of its content types and the parts they place, read as the record page's
//! editor reads them (hand.zig), and where edits are saved.
const std = @import("std");
const admin = @import("../../admin.zig");
const files = @import("files.zig");
const hand = @import("hand.zig");
const App = @import("../../apps/state.zig").App;

const Session = admin.Session;
const Writer = std.Io.Writer;

/// The app's whole library for the design system builder, as JSON for `data-library`:
/// its patterns, the template of every route showing a content type (each with what it
/// shows filled in from a published record, as on that record's page), the parts they
/// place, and where edits are saved.
pub fn library_json(session: *Session, app: *const App) ![]const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(app.spec.name.len > 0);

    const arena = session.arena;
    const program = app.program orelse return "";
    var out: Writer.Allocating = .init(arena);
    var json: std.json.Stringify = .{
        .writer = &out.writer,
    };
    var first_page: ?[]const u8 = null;

    try json.beginObject();
    try json.objectField("templates");
    try json.beginArray();

    for (program.routes) |*route| {
        const handle = files.shown_type(app, route) orelse continue;
        const page = try files.rendered(session, app, route, .{
            .handle = handle,
        });
        const source = try hand.template_of(session, app, route, page) orelse continue;

        const label = try arena.dupe(u8, handle);

        label[0] = std.ascii.toUpper(label[0]);
        first_page = first_page orelse page;
        try json.write(.{
            .name = source.label,
            .label = label,
            .html = source.html,
            .overridden = source.overridden,
            .description = source.label,
        });
    }

    try json.endArray();
    try json.objectField("parts");
    try write_part_list(session, &json, app, first_page);
    try json.objectField("patterns");
    try json.beginWriteRaw();
    try out.writer.writeAll(try hand.patterns_json(session, app));
    json.endWriteRaw();
    try json.objectField("saveUrl");
    try json.write(try hand.save_url(session, app));
    try json.endObject();

    return out.written();
}

/// The parts as a list of sources, each named: what the builder's Templates page lists.
fn write_part_list(
    session: *Session,
    json: *std.json.Stringify,
    app: *const App,
    page: ?[]const u8,
) !void {
    std.debug.assert(app.spec.name.len > 0);
    std.debug.assert(session.signed_in());

    var keyed: Writer.Allocating = .init(session.arena);
    var by_name: std.json.Stringify = .{
        .writer = &keyed.writer,
    };

    try hand.write_parts(session, &by_name, app, page);

    const parsed = try std.json.parseFromSliceLeaky(
        std.json.Value,
        session.arena,
        keyed.written(),
        .{},
    );

    try json.beginArray();

    for (parsed.object.keys(), parsed.object.values()) |name, source| {
        try json.write(.{
            .name = name,
            .label = source.object.get("label").?.string,
            .html = source.object.get("html").?.string,
            .overridden = source.object.get("overridden").?.bool,
            .area = name,
        });
    }

    try json.endArray();
}
