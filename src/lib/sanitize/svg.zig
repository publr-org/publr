//! Inline SVG for the sanitizer: which elements and attributes stay, and what their values
//! may say. Drawing stays; nothing that runs, loads from elsewhere or styles the page does:
//! no `<style>` or `style` (inline SVG's styles reach the whole page), references only to
//! the drawing's own parts (`#id`, `url(#id)`), links by the site's rules, an animation
//! never aimed at an address, a style or a handler. Ids are prefixed (`svg-`) with every
//! reference to them, so a drawing cannot stand in for one of the page's own names.

const std = @import("std");
const url = @import("url.zig");

pub const id_prefix = "svg-";

const elements = [_][]const u8{
    "svg",                 "g",              "defs",               "symbol",
    "use",                 "desc",           "title",              "metadata",
    "path",                "rect",           "circle",             "ellipse",
    "line",                "polyline",       "polygon",            "text",
    "tspan",               "textpath",       "lineargradient",     "radialgradient",
    "stop",                "pattern",        "clippath",           "mask",
    "marker",              "filter",         "feblend",            "fecolormatrix",
    "fecomponenttransfer", "fecomposite",    "feconvolvematrix",   "fediffuselighting",
    "fedisplacementmap",   "fedistantlight", "feflood",            "fefunca",
    "fefuncb",             "fefuncg",        "fefuncr",            "fegaussianblur",
    "feimage",             "femerge",        "femergenode",        "femorphology",
    "feoffset",            "fepointlight",   "fespecularlighting", "fespotlight",
    "fetile",              "feturbulence",   "animate",            "animatemotion",
    "animatetransform",    "image",          "a",                  "switch",
};

const animations = [_][]const u8{ "animate", "animatemotion", "animatetransform" };

const attributes = [_][]const u8{
    "id",                  "class",                       "lang",              "role",
    "x",                   "y",                           "x1",                "x2",
    "y1",                  "y2",                          "cx",                "cy",
    "r",                   "rx",                          "ry",                "width",
    "height",              "d",                           "points",            "viewbox",
    "preserveaspectratio", "transform",                   "fill",              "stroke",
    "fill-opacity",        "stroke-opacity",              "stroke-width",      "stroke-dasharray",
    "stroke-dashoffset",   "stroke-linecap",              "stroke-linejoin",   "stroke-miterlimit",
    "opacity",             "color",                       "display",           "visibility",
    "overflow",            "clip",                        "clip-path",         "clip-rule",
    "mask",                "filter",                      "fill-rule",         "paint-order",
    "vector-effect",       "shape-rendering",             "image-rendering",   "text-rendering",
    "color-interpolation", "color-interpolation-filters", "font-family",       "font-size",
    "font-style",          "font-weight",                 "font-variant",      "text-anchor",
    "text-decoration",     "letter-spacing",              "word-spacing",      "dominant-baseline",
    "alignment-baseline",  "baseline-shift",              "direction",         "writing-mode",
    "textlength",          "lengthadjust",                "dx",                "dy",
    "rotate",              "startoffset",                 "method",            "spacing",
    "href",                "xlink:href",                  "xlink:title",       "xmlns",
    "xmlns:xlink",         "xml:space",                   "xml:lang",          "version",
    "gradientunits",       "gradienttransform",           "spreadmethod",      "fx",
    "fy",                  "fr",                          "offset",            "patternunits",
    "patterncontentunits", "patterntransform",            "markerwidth",       "markerheight",
    "markerunits",         "refx",                        "refy",              "orient",
    "marker-start",        "marker-mid",                  "marker-end",        "filterunits",
    "primitiveunits",      "in",                          "in2",               "result",
    "mode",                "operator",                    "k1",                "k2",
    "k3",                  "k4",                          "stddeviation",      "radius",
    "edgemode",            "scale",                       "diffuseconstant",   "specularconstant",
    "specularexponent",    "surfacescale",                "kernelmatrix",      "kernelunitlength",
    "order",               "bias",                        "divisor",           "targetx",
    "targety",             "type",                        "values",            "tablevalues",
    "slope",               "intercept",                   "amplitude",         "exponent",
    "azimuth",             "elevation",                   "limitingconeangle", "pointsatx",
    "pointsaty",           "pointsatz",                   "flood-color",       "flood-opacity",
    "lighting-color",      "stop-color",                  "stop-opacity",      "attributename",
    "attributetype",       "begin",                       "dur",               "end",
    "repeatcount",         "repeatdur",                   "restart",           "from",
    "to",                  "by",                          "calcmode",          "keysplines",
    "keytimes",            "additive",                    "accumulate",        "keypoints",
    "requiredextensions",  "systemlanguage",              "aria-label",        "aria-hidden",
    "focusable",
};

pub fn element(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    return listed(&elements, name);
}

/// The value an attribute of a drawing's element keeps, rewritten where it names an id;
/// null when the attribute goes.
pub fn attribute(
    arena: std.mem.Allocator,
    tag: []const u8,
    name: []const u8,
    value: []const u8,
) !?[]const u8 {
    std.debug.assert(tag.len > 0);
    std.debug.assert(name.len > 0);

    if (!listed(&attributes, name)) {
        return null;
    }

    if (std.mem.eql(u8, name, "id")) {
        return try std.fmt.allocPrint(arena, id_prefix ++ "{s}", .{value});
    }

    if (std.mem.eql(u8, name, "attributename")) {
        return if (animated_safely(value)) value else null;
    }

    if (std.mem.eql(u8, name, "href") or std.mem.eql(u8, name, "xlink:href")) {
        return address(arena, tag, value);
    }

    if (std.ascii.indexOfIgnoreCase(value, "url(") != null) {
        return local_urls(arena, value);
    }

    return value;
}

/// A link goes where any link may; an image may also be a raster `data:` image; anything
/// else points only at the drawing's own parts.
fn address(arena: std.mem.Allocator, tag: []const u8, value: []const u8) !?[]const u8 {
    std.debug.assert(tag.len > 0);

    if (std.mem.eql(u8, tag, "a")) {
        return if (url.safe(value)) value else null;
    }

    const image = std.mem.eql(u8, tag, "image") or std.mem.eql(u8, tag, "feimage");

    if (image and (url.safe(value) or raster(value))) {
        return value;
    }

    if (value.len > 1 and value[0] == '#' and plain_id(value[1..])) {
        return try std.fmt.allocPrint(arena, "#" ++ id_prefix ++ "{s}", .{value[1..]});
    }

    return null;
}

/// Every `url(...)` in the value names one of the drawing's own parts, rewritten to its
/// prefixed id; null when one names anything else.
fn local_urls(arena: std.mem.Allocator, value: []const u8) !?[]const u8 {
    std.debug.assert(value.len > 0);

    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;

    while (std.ascii.indexOfIgnoreCasePos(value, at, "url(")) |start| {
        const inner_start: u32 = @intCast(start + 4);
        const end = std.mem.indexOfScalarPos(u8, value, inner_start, ')') orelse return null;
        const inner = std.mem.trim(u8, value[inner_start..end], " \t'\"");

        if (inner.len < 2 or inner[0] != '#' or !plain_id(inner[1..])) {
            return null;
        }

        try out.appendSlice(arena, value[at..start]);
        try out.print(arena, "url(#" ++ id_prefix ++ "{s})", .{inner[1..]});
        at = @intCast(end + 1);
    }

    try out.appendSlice(arena, value[at..]);

    return out.items;
}

/// An animation may move, turn, colour or fade a drawing; never change an address, a
/// style or a handler.
fn animated_safely(value: []const u8) bool {
    std.debug.assert(value.len <= 4 << 20);

    const banned = [_][]const u8{ "href", "src", "style", "action", "data" };

    for (banned) |word| {
        if (std.ascii.indexOfIgnoreCase(value, word) != null) {
            return false;
        }
    }

    const trimmed = std.mem.trim(u8, value, " \t\r\n");

    return trimmed.len > 0 and !std.ascii.startsWithIgnoreCase(trimmed, "on");
}

pub fn animation(name: []const u8) bool {
    std.debug.assert(name.len > 0);

    return listed(&animations, name);
}

fn raster(value: []const u8) bool {
    std.debug.assert(value.len <= 4 << 20);

    const kinds = [_][]const u8{
        "data:image/png;", "data:image/gif;", "data:image/jpeg;", "data:image/webp;",
    };

    for (kinds) |kind| {
        if (std.ascii.startsWithIgnoreCase(value, kind)) {
            return true;
        }
    }

    return false;
}

fn plain_id(text: []const u8) bool {
    std.debug.assert(text.len <= 4 << 20);

    if (text.len == 0 or text.len > 128) {
        return false;
    }

    for (text) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '-' and char != '_' and char != '.') {
            return false;
        }
    }

    return true;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len > 0);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}
