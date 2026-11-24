//! Pages handed to the host to draw (`publr_draw`) that are wrong: a page, its markup, its
//! components, a component's name, its layout or its props lying outside the memory or
//! longer than it; more components than a page may have; a prop that is not the
//! component's; a placeholder that names no component or never ends; a component an
//! installed plugin may not draw. One honest page proves the frame was there.
const std = @import("std");

const Slice = extern struct {
    ptr: u32,
    len: u32,
};

const Page = extern struct {
    markup: u32,
    markup_len: u32,
    components: u32 = 0,
    components_len: u32 = 0,
};

const Component = extern struct {
    name: u32,
    name_len: u32,
    described: u32,
    described_len: u32,
    props: u32,
    table: u32 = 0,
    table_len: u32 = 0,
};

extern "env" fn publr_frame(
    base: [*]const u8,
    base_len: u32,
    wanted: *const Slice,
    sizes: *[2]u32,
) u32;
extern "env" fn publr_draw(page: *const Page, result: *Slice) u32;

const outside: u32 = 0xffff_fff0;

/// A struct of no fields: all the frame is asked to say.
const nothing = [_]u8{ 'o', 0, 0, 0, 0, 0, 0, 0, 0, 0 };
/// A struct of one text, `tone`, at its start.
const one_text = [_]u8{ 'o', 0, 8, 0, 0, 0, 1, 0, 0, 0, 4, 't', 'o', 'n', 'e' } ++
    [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 's' };
const cut_short = [_]u8{ 'o', 0, 8, 0, 0, 0, 9, 0, 0, 0 };

fn address(pointer: anytype) u32 {
    return @intCast(@intFromPtr(pointer));
}

pub const Drawn = struct {
    /// How a page of markup alone ended: 0
    honest: u32,
    /// How each wrong page ended: every one `Invalid`
    refused: [wrong_count]u32,
    /// How a page naming a component a plugin may not draw ended: `NotFound`
    unknown: u32,
};

pub const wrong_count: u32 = 15;

pub fn drawn() Drawn {
    var sizes: [2]u32 = .{ 0, 0 };
    var result: Slice = .{
        .ptr = 0,
        .len = 0,
    };
    const wanted: Slice = .{
        .ptr = address(&nothing),
        .len = nothing.len,
    };
    const markup = "<b>ok</b>";
    const none = "<publr-drawn n=\"5\">";
    const endless = "<publr-drawn n=\"0\"";
    const placed = "<publr-drawn n=\"0\">";
    const status = "Status";
    const content = "Content";
    const bogus = "bogus";
    const tone: Slice = .{
        .ptr = address(bogus.ptr),
        .len = bogus.len,
    };
    var component: Component = .{
        .name = address(status.ptr),
        .name_len = status.len,
        .described = address(&one_text),
        .described_len = one_text.len,
        .props = address(&tone),
    };
    var page: Page = .{
        .markup = address(markup.ptr),
        .markup_len = markup.len,
    };
    var out: Drawn = undefined;
    var at: u32 = 0;

    // Before any frame: nothing to draw with.
    out.refused[at] = publr_draw(&page, &result);
    at += 1;

    std.debug.assert(publr_frame("", 0, &wanted, &sizes) == 0);

    out.honest = publr_draw(&page, &result);
    out.refused[at] = publr_draw(@ptrFromInt(outside), &result);
    at += 1;

    const wrong_pages = [_][4]u32{
        .{ outside, 8, 0, 0 },
        .{ page.markup, 0xffff_ffff, 0, 0 },
        .{ page.markup, 9, outside, 1 },
        .{ page.markup, 9, address(&component), 0xffff_ffff },
        .{ address(none.ptr), none.len, 0, 0 },
        .{ address(endless.ptr), endless.len, 0, 0 },
    };

    for (wrong_pages) |wrong| {
        page = .{
            .markup = wrong[0],
            .markup_len = wrong[1],
            .components = wrong[2],
            .components_len = wrong[3],
        };
        out.refused[at] = publr_draw(&page, &result);
        at += 1;
    }

    page = .{
        .markup = address(placed.ptr),
        .markup_len = placed.len,
        .components = address(&component),
        .components_len = 1,
    };

    // A prop that is not one of the component's values.
    out.refused[at] = publr_draw(&page, &result);
    at += 1;

    // Its name, its layout and its props, each outside the memory or of no length.
    const honest = component;
    const wrong_parts = [_][5]u32{
        .{ outside, 6, honest.described, one_text.len, honest.props },
        .{ honest.name, 0, honest.described, one_text.len, honest.props },
        .{ honest.name, 6, outside, 24, honest.props },
        .{ honest.name, 6, address(&cut_short), cut_short.len, honest.props },
        .{ honest.name, 6, honest.described, 0, honest.props },
        .{ honest.name, 6, honest.described, one_text.len, outside },
    };

    for (wrong_parts) |wrong| {
        component = .{
            .name = wrong[0],
            .name_len = wrong[1],
            .described = wrong[2],
            .described_len = wrong[3],
            .props = wrong[4],
        };
        out.refused[at] = publr_draw(&page, &result);
        at += 1;
    }

    component = .{
        .name = address(content.ptr),
        .name_len = content.len,
        .described = address(&nothing),
        .described_len = nothing.len,
        .props = address(&tone),
    };
    out.unknown = publr_draw(&page, &result);

    std.debug.assert(at == wrong_count);

    return out;
}
