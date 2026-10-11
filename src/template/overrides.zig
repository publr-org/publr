//! A rendered page with its app's published design overrides applied: the route's template
//! in place of the page's `data-publr-template` region, each slot of it given what the
//! file's own region rendered into the slot of that name, and each template part's inside
//! replaced by the part's override. Overrides are written in the admin, so their markup is
//! sanitized first; the file's own markup is the app's and is kept as it is. Pure.

const std = @import("std");
const sanitize = @import("../lib/sanitize.zig");
const regions = @import("regions.zig");

const Named = regions.Named;
const Range = regions.Range;
const Region = regions.Region;

pub const Part = struct {
    name: []const u8,
    output: []const u8,
};

pub const Overrides = struct {
    /// The route's template override's output; null when the route has none.
    template: ?[]const u8 = null,
    parts: []const Part = &.{},
};

/// Where a slot or a part sits in the sanitized template until it is filled: text the
/// sanitizer keeps as it is. A template holding it already is not applied.
const placeholder = "publr-design-marker-";

/// The page with `overrides` applied; the page itself, byte for byte, when none applies.
pub fn apply(arena: std.mem.Allocator, page: []const u8, overrides: Overrides) ![]const u8 {
    std.debug.assert(page.len < 1 << 31);
    std.debug.assert(overrides.parts.len <= regions.named_max * 64);

    if (overrides.template == null and overrides.parts.len == 0) {
        return page;
    }

    const parts = try arena.alloc(Part, overrides.parts.len);

    for (overrides.parts, parts) |part, *clean| {
        const output = try sanitize.sanitize(arena, part.output, .content);

        clean.* = .{
            .name = part.name,
            .output = output,
        };
    }

    var html = page;

    if (overrides.template) |output| {
        if (try with_template(arena, html, output, parts)) |swapped| {
            html = swapped;
        }
    }

    return with_parts(arena, html, parts);
}

fn whole(html: []const u8) Range {
    std.debug.assert(html.len < 1 << 31);

    return .{
        .start = 0,
        .end = @intCast(html.len),
    };
}

fn with_template(
    arena: std.mem.Allocator,
    page: []const u8,
    output: []const u8,
    parts: []const Part,
) !?[]const u8 {
    std.debug.assert(output.len < 1 << 31);
    std.debug.assert(page.len < 1 << 31);

    const region = regions.find(page, whole(page), regions.template_attribute, null) orelse
        return null;

    if (std.mem.indexOf(u8, output, placeholder) != null) {
        return null;
    }

    var buffer: [regions.named_max]Named = undefined;
    const attributes = [_][]const u8{ regions.slot_attribute, regions.part_attribute };
    const markers = regions.list(output, whole(output), &attributes, &buffer);
    var prepared: std.Io.Writer.Allocating = .init(arena);
    var at: u32 = 0;

    for (markers, 0..) |marker, index| {
        const inner = marker.region.inner;

        if (marker.region.close.start == marker.region.close.end) {
            continue;
        }

        try prepared.writer.print("{s}{s}{d}.", .{ output[at..inner.start], placeholder, index });
        at = inner.end;
    }

    try prepared.writer.writeAll(output[at..]);

    const clean = try sanitize.sanitize(arena, prepared.written(), .content);
    var filled: std.Io.Writer.Allocating = .init(arena);
    const file: Filling = .{
        .page = page,
        .region = region,
        .markers = markers,
        .parts = parts,
    };

    try filled.writer.writeAll(page[0..region.inner.start]);
    try fill(&filled.writer, clean, file);
    try filled.writer.writeAll(page[region.inner.end..]);

    return filled.written();
}

const Filling = struct {
    page: []const u8,
    region: Region,
    markers: []const Named,
    parts: []const Part,
};

/// The sanitized template with every placeholder replaced by what its marker stands for.
fn fill(writer: *std.Io.Writer, clean: []const u8, file: Filling) !void {
    std.debug.assert(file.markers.len <= regions.named_max);
    std.debug.assert(file.region.inner.end <= file.page.len);

    var at: u32 = 0;

    while (std.mem.indexOfPos(u8, clean, at, placeholder)) |found| {
        const digits_start = found + placeholder.len;
        const dot = std.mem.indexOfScalarPos(u8, clean, digits_start, '.') orelse break;
        const index = std.fmt.parseInt(u32, clean[digits_start..dot], 10) catch break;

        if (index >= file.markers.len) {
            break;
        }

        try writer.writeAll(clean[at..found]);
        try writer.writeAll(content_of(file, file.markers[index]));
        at = @intCast(dot + 1);
    }

    try writer.writeAll(clean[at..]);
}

/// A slot: what the file's region rendered into its slot of that name. A part: its
/// override, else what the file rendered into a part of that name anywhere on the page.
fn content_of(file: Filling, marker: Named) []const u8 {
    std.debug.assert(marker.name.len <= 1 << 20);
    std.debug.assert(file.region.inner.end <= file.page.len);

    const page = file.page;

    if (std.mem.eql(u8, marker.attribute, regions.slot_attribute)) {
        const slot = regions.find(page, file.region.inner, regions.slot_attribute, marker.name);

        return if (slot) |found| found.inner.of(page) else "";
    }

    for (file.parts) |part| {
        if (std.mem.eql(u8, part.name, marker.name)) {
            return part.output;
        }
    }

    const part = regions.find(page, whole(page), regions.part_attribute, marker.name);

    return if (part) |found| found.inner.of(page) else "";
}

/// Every part on the page with an override, its inside replaced by the override.
fn with_parts(arena: std.mem.Allocator, page: []const u8, parts: []const Part) ![]const u8 {
    std.debug.assert(page.len < 1 << 31);

    if (parts.len == 0) {
        return page;
    }

    var buffer: [regions.named_max]Named = undefined;
    const placed = regions.list(page, whole(page), &.{regions.part_attribute}, &buffer);
    var out: std.Io.Writer.Allocating = .init(arena);
    var at: u32 = 0;

    for (placed) |marker| {
        const part = for (parts) |candidate| {
            if (std.mem.eql(u8, candidate.name, marker.name)) {
                break candidate;
            }
        } else continue;

        try out.writer.writeAll(page[at..marker.region.inner.start]);
        try out.writer.writeAll(part.output);
        at = marker.region.inner.end;
    }

    if (at == 0) {
        return page;
    }

    try out.writer.writeAll(page[at..]);

    std.debug.assert(out.written().len > 0);

    return out.written();
}

const testing = std.testing;

const file_page = "<html><body><header data-publr-template-part=\"header\">File head</header>" ++
    "<main data-publr-template><h1 data-publr-slot=\"title\">Hello</h1>" ++
    "<div data-publr-slot=\"content\"><p>Body <script>run()</script></p></div></main>" ++
    "<script>window.app = 1</script></body></html>";

test "apply: no overrides, or none that match, leave the page as it is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(file_page.ptr, (try apply(arena, file_page, .{})).ptr);

    const other = [_]Part{.{
        .name = "footer",
        .output = "<p>F</p>",
    }};

    try testing.expectEqualStrings(file_page, try apply(arena, file_page, .{
        .parts = &other,
    }));

    const plain = "<p>No markers</p>";

    try testing.expectEqualStrings(plain, try apply(arena, plain, .{
        .template = "<div></div>",
    }));
}

test "apply: the template replaces the region, slots keep the file's own render" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const template = "<section class=\"wide\" onclick=\"x()\">" ++
        "<h2 data-publr-slot=\"title\"></h2>" ++
        "<script>evil()</script><div data-publr-slot=\"content\"></div><p>Bye</p></section>";
    const html = try apply(arena, file_page, .{
        .template = template,
    });

    try testing.expectEqualStrings("<html><body><header data-publr-template-part=\"header\">" ++
        "File head</header><main data-publr-template><section class=\"wide\"><h2>Hello</h2>" ++
        "<div><p>Body <script>run()</script></p></div><p>Bye</p></section></main>" ++
        "<script>window.app = 1</script></body></html>", html);
}

test "apply: parts anywhere, inside the template too, take their override sanitized" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = [_]Part{.{
        .name = "header",
        .output = "<b>New</b><img src=x onerror=y()>",
    }};
    const html = try apply(arena, file_page, .{
        .parts = &parts,
    });

    try testing.expect(std.mem.indexOf(u8, html, "File head") == null);
    try testing.expect(std.mem.indexOf(u8, html, "onerror") == null);
    try testing.expect(std.mem.indexOf(u8, html, "<b>New</b>") != null);

    const template = "<div data-publr-template-part=\"header\"></div>" ++
        "<div data-publr-template-part=\"aside\"></div><div data-publr-slot=\"content\"></div>";
    const with_both = try apply(arena, file_page, .{
        .template = template,
        .parts = &parts,
    });
    const kept = try apply(arena, file_page, .{
        .template = template,
    });

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, with_both, "<b>New</b>"));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, kept, "File head"));
}

test "apply: a template that holds the placeholder text is not applied" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const template = "<p>publr-design-marker-0.</p><div data-publr-slot=\"content\"></div>";

    const html = try apply(arena, file_page, .{
        .template = template,
    });

    try testing.expectEqualStrings(file_page, html);
}
