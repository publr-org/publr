//! Regions of rendered HTML marked by an attribute: the element carrying
//! `data-publr-template`, `data-publr-template-part="<name>"` or `data-publr-slot="<name>"`,
//! as the byte ranges of its open tag, its inner content and its end tag. Elements nest by
//! tag name; void elements and self-closed tags have no inside; script, style, textarea and
//! title hold raw text. An element whose end never comes is no region. Pure.

const std = @import("std");
const tags = @import("regions/tags.zig");

pub const template_attribute = "data-publr-template";
pub const part_attribute = "data-publr-template-part";
pub const slot_attribute = "data-publr-slot";
pub const named_max: u32 = 128;

pub const Range = tags.Range;
const Scanner = tags.Scanner;
const Tag = tags.Tag;

pub const Region = struct {
    open: Range,
    inner: Range,
    close: Range,
};

/// A marked element and the value of its marker: a part's or a slot's name.
pub const Named = struct {
    attribute: []const u8,
    name: []const u8,
    region: Region,
};

/// The first element in `within` carrying `attribute` (with `value`, when given).
pub fn find(html: []const u8, within: Range, attribute: []const u8, value: ?[]const u8) ?Region {
    std.debug.assert(within.end <= html.len);
    std.debug.assert(attribute.len > 0);

    var scanner: Scanner = .{
        .html = html,
        .at = within.start,
        .end = within.end,
    };

    while (scanner.next()) |tag| {
        if (tag.kind != .start) {
            continue;
        }

        const found = tags.attribute_of(html, tag, attribute) orelse continue;

        if (value) |wanted| {
            if (!std.mem.eql(u8, found, wanted)) {
                continue;
            }
        }

        return region_of(&scanner, tag);
    }

    return null;
}

/// Every element in `within` carrying one of `attributes`, outermost only, in order, up
/// to `buffer.len`: what is inside a marked element is not listed apart.
pub fn list(
    html: []const u8,
    within: Range,
    attributes: []const []const u8,
    buffer: []Named,
) []Named {
    std.debug.assert(within.end <= html.len);
    std.debug.assert(attributes.len > 0);

    var scanner: Scanner = .{
        .html = html,
        .at = within.start,
        .end = within.end,
    };
    var count: u32 = 0;

    while (count < buffer.len) {
        const tag = scanner.next() orelse break;

        if (tag.kind != .start) {
            continue;
        }

        for (attributes) |attribute| {
            const name = tags.attribute_of(html, tag, attribute) orelse continue;
            const region = region_of(&scanner, tag) orelse break;

            buffer[count] = .{
                .attribute = attribute,
                .name = name,
                .region = region,
            };
            count += 1;
            scanner.at = region.close.end;

            break;
        }
    }

    return buffer[0..count];
}

/// The whole of the element `open` starts, the scanner left after its end tag.
fn region_of(scanner: *Scanner, open: Tag) ?Region {
    std.debug.assert(open.kind == .start);
    std.debug.assert(scanner.at >= open.end);

    const at_open: Range = .{
        .start = open.start,
        .end = open.end,
    };
    const empty: Range = .{
        .start = open.end,
        .end = open.end,
    };

    if (open.self_closing or tags.is_void(open.name)) {
        return .{
            .open = at_open,
            .inner = empty,
            .close = empty,
        };
    }

    var depth: u32 = 1;

    while (scanner.next()) |tag| {
        if (!std.ascii.eqlIgnoreCase(tag.name, open.name)) {
            continue;
        }

        if (tag.kind == .start and !tag.self_closing) {
            depth += 1;
        } else if (tag.kind == .end) {
            depth -= 1;

            if (depth == 0) {
                return .{
                    .open = at_open,
                    .inner = .{
                        .start = open.end,
                        .end = tag.start,
                    },
                    .close = .{
                        .start = tag.start,
                        .end = tag.end,
                    },
                };
            }
        }
    }

    return null;
}

fn whole(html: []const u8) Range {
    std.debug.assert(html.len < 1 << 31);

    return .{
        .start = 0,
        .end = @intCast(html.len),
    };
}

const testing = std.testing;

test {
    _ = tags;
}

test "find: the marked element, nested same-name tags counted" {
    const html = "<body><div data-publr-template class=\"x\"><div>a</div><p>b</p></div><i></i>";
    const region = find(html, whole(html), template_attribute, null).?;

    try testing.expectEqualStrings("<div data-publr-template class=\"x\">", region.open.of(html));
    try testing.expectEqualStrings("<div>a</div><p>b</p>", region.inner.of(html));
    try testing.expectEqualStrings("</div>", region.close.of(html));
    try testing.expect(find(html, whole(html), slot_attribute, null) == null);
}

test "find: values, quotes, case and a part's name is not the template's marker" {
    const html = "<HEADER DATA-PUBLR-TEMPLATE-PART='top' title=\"a > b\">x</header>" ++
        "<div data-publr-slot=content>c</div>";
    const part = find(html, whole(html), part_attribute, "top").?;

    try testing.expectEqualStrings("x", part.inner.of(html));
    try testing.expect(find(html, whole(html), part_attribute, "bottom") == null);
    try testing.expect(find(html, whole(html), template_attribute, null) == null);
    try testing.expectEqualStrings(
        "c",
        find(html, whole(html), slot_attribute, "content").?.inner.of(html),
    );
}

test "find: raw text, comments, void and self-closed elements" {
    const html = "<script>if (a < b) { '<div data-publr-slot=\"x\">' }</script>" ++
        "<!-- <div data-publr-slot=\"x\"> --><img data-publr-slot=\"x\">" ++
        "<span data-publr-slot=\"y\"/>" ++
        "<div data-publr-slot=\"z\"><style>p{}</div></style></div>";
    const image = find(html, whole(html), slot_attribute, "x").?;

    try testing.expect(std.mem.startsWith(u8, image.open.of(html), "<img"));
    try testing.expectEqual(@as(usize, 0), image.inner.of(html).len);
    const closed = find(html, whole(html), slot_attribute, "y").?;

    try testing.expectEqual(@as(usize, 0), closed.inner.of(html).len);
    try testing.expectEqualStrings(
        "<style>p{}</div></style>",
        find(html, whole(html), slot_attribute, "z").?.inner.of(html),
    );
}

test "find: malformed input is no region, never a crash" {
    const cases = [_][]const u8{
        "",
        "<",
        "<div data-publr-template>never closed",
        "<div data-publr-template",
        "<div data-publr-template=\"unterminated>",
        "</div><div data-publr-template><<>></span>",
        "<div data-publr-template><!-- open comment",
        "<script data-publr-template>",
        "<!doctype html",
        "<div data-publr-template=>x</div",
    };

    for (cases) |html| {
        try testing.expect(find(html, whole(html), template_attribute, null) == null);
    }

    const bare = "<div data-publr-template=>x</div>";

    const found = find(bare, whole(bare), template_attribute, null).?;

    try testing.expectEqualStrings("x", found.inner.of(bare));
}

test "list: parts and slots in order, outermost only, within a range, bounded" {
    const html = "<header data-publr-template-part=\"head\">" ++
        "<div data-publr-slot=\"title\"></div></header>" ++
        "<main data-publr-template><h1 data-publr-slot=\"title\">T</h1>" ++
        "<div data-publr-template-part=\"aside\">A</div>" ++
        "<div data-publr-slot=\"content\">C</div></main>";
    var buffer: [named_max]Named = undefined;
    const parts = list(html, whole(html), &.{part_attribute}, &buffer);

    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("head", parts[0].name);
    try testing.expectEqualStrings("aside", parts[1].name);

    const region = find(html, whole(html), template_attribute, null).?;
    const markers = list(html, region.inner, &.{ slot_attribute, part_attribute }, &buffer);

    try testing.expectEqual(@as(usize, 3), markers.len);
    try testing.expectEqualStrings("T", markers[0].region.inner.of(html));
    try testing.expectEqualStrings(part_attribute, markers[1].attribute);
    try testing.expectEqualStrings("C", markers[2].region.inner.of(html));

    var one: [1]Named = undefined;

    try testing.expectEqual(@as(usize, 1), list(html, whole(html), &.{slot_attribute}, &one).len);
    const none = list("<p>", whole("<p>"), &.{slot_attribute}, &buffer);

    try testing.expectEqual(@as(usize, 0), none.len);
}
