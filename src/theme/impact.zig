//! What a record type reaches in a loaded theme: the pages whose render reads it, itself
//! or through what it embeds, and the islands that do, each with the pages that place it.
//! Pure: read from the compiled templates, never from a build.

const std = @import("std");
const ast = @import("ast.zig");
const theme_module = @import("../theme.zig");

const Template = ast.Template;
const Theme = theme_module.Theme;
const templates_max = theme_module.templates_max;

/// Strongest last: a template that reads the entry itself outranks one that lists it.
pub const Reads = enum(u8) { none = 0, query = 1, entry = 2 };

pub const Placement = struct {
    route: []const u8,
    /// The page's placeholder is the build's own render: a stale copy until the page is
    /// next built, since the page is not subscribed to what the island reads.
    prerendered: bool,
};

pub const Page = struct {
    route: []const u8,
    template: []const u8,
    /// Rendered per request, never built.
    live: bool,
    reads: Reads,
    /// The embedded template that does the reading; empty when the page does it itself.
    via: []const u8,
};

pub const Island = struct {
    key: []const u8,
    template: []const u8,
    dynamic: bool,
    reads: Reads,
    via: []const u8,
    placed: []const Placement,
    /// The islands whose fragment carries this one.
    inside: []const []const u8,
};

pub const Impact = struct { pages: []const Page, islands: []const Island };

pub const Error = std.mem.Allocator.Error || error{TooManyPending};

/// Sibling subtrees waiting to be walked, across every level of one template.
pub const pending_max: u32 = 4096;

pub fn of(arena: std.mem.Allocator, theme: *const Theme, type_id: []const u8) Error!Impact {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(theme.templates.len <= templates_max);

    var pages: std.ArrayList(Page) = .empty;

    for (theme.routes) |route| {
        const found = try reach(arena, theme, route.template, type_id);

        if (found.reads == .none) {
            continue;
        }

        try pages.append(arena, .{
            .route = route.pattern,
            .template = theme.templates[route.template].rel,
            .live = route.live,
            .reads = found.reads,
            .via = found.via,
        });
    }

    var islands: std.ArrayList(Island) = .empty;

    for (theme.islands) |island| {
        const found = try reach(arena, theme, island.template, type_id);

        if (found.reads == .none) {
            continue;
        }

        try islands.append(arena, .{
            .key = island.key,
            .template = theme.templates[island.template].rel,
            .dynamic = island.dynamic,
            .reads = found.reads,
            .via = found.via,
            .placed = try placed_of(arena, theme, island.key),
            .inside = try inside_of(arena, theme, island.key),
        });
    }

    std.debug.assert(pages.items.len <= theme.routes.len);
    std.debug.assert(islands.items.len <= theme.islands.len);

    return .{ .pages = pages.items, .islands = islands.items };
}

/// Classify a type without allocating an impact report or visiting islands. Scratch
/// storage is released after each route so a request's arena does not grow with routes.
pub fn has_entry_page(
    arena: std.mem.Allocator,
    theme: *const Theme,
    type_id: []const u8,
) Error!bool {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(theme.templates.len <= templates_max);

    for (theme.routes) |route| {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();

        const found = try reach(scratch.allocator(), theme, route.template, type_id);

        if (found.reads == .entry) {
            return true;
        }
    }

    return false;
}

const Found = struct { reads: Reads, via: []const u8 };

/// The strongest read of `type_id` from `start` through every template it embeds,
/// breadth first, each template once. Islands are fragments of their own: not followed.
fn reach(
    arena: std.mem.Allocator,
    theme: *const Theme,
    start: u32,
    type_id: []const u8,
) Error!Found {
    std.debug.assert(start < theme.templates.len);
    std.debug.assert(type_id.len > 0);

    var visited = std.StaticBitSet(templates_max).initEmpty();
    var queue: [templates_max]u32 = undefined;
    var head: u32 = 0;
    var tail: u32 = 1;
    var found: Found = .{ .reads = .none, .via = "" };

    queue[0] = start;
    visited.set(start);

    while (head < tail) : (head += 1) {
        const index = queue[head];
        const template = &theme.templates[index];
        const own = direct(template, type_id);

        if (@intFromEnum(own) > @intFromEnum(found.reads)) {
            found = .{ .reads = own, .via = if (index == start) "" else template.rel };
        }

        for (try embeds_of(arena, template)) |callee| {
            if (visited.isSet(callee)) {
                continue;
            }

            visited.set(callee);
            queue[tail] = callee;
            tail += 1;
        }
    }

    std.debug.assert(tail <= theme.templates.len);

    return found;
}

/// What the template's own frontmatter reads of the type.
fn direct(template: *const Template, type_id: []const u8) Reads {
    std.debug.assert(type_id.len > 0);
    std.debug.assert(template.rel.len > 0);

    var reads: Reads = .none;

    for (template.decls) |decl| {
        const own: Reads = switch (decl.value) {
            .entry => |entry| if (std.mem.eql(u8, entry.type_id, type_id)) .entry else .none,
            .query => |query| if (std.mem.eql(u8, query.type_id, type_id)) .query else .none,
            else => .none,
        };

        if (@intFromEnum(own) > @intFromEnum(reads)) {
            reads = own;
        }
    }

    return reads;
}

/// Every template this one embeds, at any depth of its markup, once each. A stack of
/// subtrees instead of recursion; an island's fallback is the page's own markup.
fn embeds_of(arena: std.mem.Allocator, template: *const Template) Error![]const u32 {
    std.debug.assert(template.compiled);
    std.debug.assert(pending_max > 0);

    var pending: std.ArrayList([]const ast.Node) = .empty;
    var callees: std.ArrayList(u32) = .empty;

    try pending.append(arena, template.body);

    while (pending.pop()) |nodes| {
        for (nodes) |node| {
            switch (node) {
                .embed => |embed| {
                    try note(arena, &callees, embed.callee);

                    if (embed.children) |children| {
                        try push(arena, &pending, children);
                    }
                },
                .loop => |loop| try push(arena, &pending, loop.body),
                .cond => |cond| {
                    try push(arena, &pending, cond.consequent);
                    try push(arena, &pending, cond.alternate);
                },
                .island => |island| try push(arena, &pending, island.fallback),
                .pjsx => |pjsx| {
                    if (pjsx.children) |children| {
                        try push(arena, &pending, children);
                    }
                },
                else => {},
            }
        }
    }

    std.debug.assert(pending.items.len == 0);

    return callees.items;
}

fn push(
    arena: std.mem.Allocator,
    pending: *std.ArrayList([]const ast.Node),
    nodes: []const ast.Node,
) Error!void {
    std.debug.assert(pending.items.len <= pending_max);
    std.debug.assert(nodes.len <= std.math.maxInt(u32));

    if (nodes.len == 0) {
        return;
    }

    if (pending.items.len == pending_max) {
        return error.TooManyPending;
    }

    try pending.append(arena, nodes);
}

fn note(arena: std.mem.Allocator, callees: *std.ArrayList(u32), callee: u32) Error!void {
    std.debug.assert(callee < templates_max);
    std.debug.assert(callees.items.len <= templates_max);

    for (callees.items) |known| {
        if (known == callee) {
            return;
        }
    }

    try callees.append(arena, callee);
}

/// The pages whose render places the island, nested fragments included.
fn placed_of(
    arena: std.mem.Allocator,
    theme: *const Theme,
    key: []const u8,
) Error![]const Placement {
    std.debug.assert(key.len > 0);
    std.debug.assert(theme.routes.len <= templates_max);

    var placed: std.ArrayList(Placement) = .empty;

    for (theme.routes) |route| {
        const template = &theme.templates[route.template];

        if (!places(template, key)) {
            continue;
        }

        try placed.append(arena, .{
            .route = route.pattern,
            .prerendered = contains(template.static_idle_keys, key),
        });
    }

    return placed.items;
}

/// The islands whose fragment places this one.
fn inside_of(
    arena: std.mem.Allocator,
    theme: *const Theme,
    key: []const u8,
) Error![]const []const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(theme.islands.len <= theme_module.islands_max);

    var inside: std.ArrayList([]const u8) = .empty;

    for (theme.islands) |other| {
        if (std.mem.eql(u8, other.key, key)) {
            continue;
        }

        if (places(&theme.templates[other.template], key)) {
            try inside.append(arena, other.key);
        }
    }

    return inside.items;
}

fn places(template: *const Template, key: []const u8) bool {
    std.debug.assert(key.len > 0);
    std.debug.assert(template.compiled);

    return contains(template.static_island_keys, key) or
        contains(template.static_idle_keys, key) or
        contains(template.dynamic_eager_keys, key) or
        contains(template.dynamic_idle_keys, key);
}

fn contains(keys: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);
    std.debug.assert(keys.len <= theme_module.islands_max);

    for (keys) |known| {
        if (std.mem.eql(u8, known, key)) {
            return true;
        }
    }

    return false;
}

const testing = std.testing;

fn source(rel: []const u8, text: []const u8) theme_module.Source {
    return .{ .rel = rel, .source = text };
}

fn load_test(sources: []const theme_module.Source) !*Theme {
    std.debug.assert(sources.len > 0);
    std.debug.assert(sources.len <= templates_max);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostic: theme_module.Diagnostic = .{ .arena = arena_state.allocator() };

    return theme_module.load(testing.allocator, sources, .{}, &diagnostic) catch |err| {
        std.debug.print("load failed: {s}\n", .{diagnostic.message});

        return err;
    };
}

fn destroy(theme: *Theme) void {
    theme.deinit();
    testing.allocator.destroy(theme);
}

test "pages that read the type themselves or through an embed, islands with their placements" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const theme = try load_test(&.{
        source("layouts/base.publr", "<html><head></head><body><slot /></body></html>"),
        source("components/latest.publr",
            \\---
            \\const posts = Publr.build.getCollection({ type: 'post', limit: 3 });
            \\---
            \\<ul>{posts.map((p) => (<li>{p.title}</li>))}</ul>
        ),
        source("components/outer.dynamic.publr",
            \\---
            \\import Latest from './latest.publr';
            \\const ua = Publr.request.header('user-agent');
            \\---
            \\<p>{ua ?? "?"}</p><Latest island eager />
        ),
        source("content/index.publr",
            \\---
            \\import Base from '../layouts/base.publr';
            \\import Latest from '../components/latest.publr';
            \\const notes = Publr.build.getCollection({ type: 'note' });
            \\---
            \\<Base>{notes.length === 0 ? (<Latest />) : null}</Base>
        ),
        source("content/posts/[slug].publr",
            \\---
            \\import Base from '../../layouts/base.publr';
            \\import Latest from '../../components/latest.publr';
            \\const post = Publr.build.getEntry();
            \\---
            \\<Base><h1>{post.title}</h1><Latest island prerender eager /></Base>
        ),
        source("content/nested.publr",
            \\---
            \\import Outer from '../components/outer.dynamic.publr';
            \\---
            \\<head></head><Outer dynamic eager />
        ),
        source("content/about.publr",
            \\---
            \\import Base from '../layouts/base.publr';
            \\---
            \\<Base><p>Nothing read here</p></Base>
        ),
    });
    defer destroy(theme);

    // Repeated classification must release traversal memory to the fixed request pool.
    var buffer: [32 << 10]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&buffer);

    for (0..64) |_| {
        try testing.expect(try has_entry_page(fixed.allocator(), theme, "post"));
        try testing.expect(!try has_entry_page(fixed.allocator(), theme, "note"));
        try testing.expect(!try has_entry_page(fixed.allocator(), theme, "unknown"));
        try testing.expectEqual(@as(usize, 0), fixed.end_index);
    }

    const impact = try of(arena, theme, "post");

    try testing.expectEqual(@as(usize, 2), impact.pages.len);
    try testing.expectEqualStrings("/", impact.pages[0].route);
    try testing.expectEqual(Reads.query, impact.pages[0].reads);
    try testing.expectEqualStrings("components/latest.publr", impact.pages[0].via);
    try testing.expect(!impact.pages[0].live);
    try testing.expectEqualStrings("/posts/:slug", impact.pages[1].route);
    try testing.expectEqual(Reads.entry, impact.pages[1].reads);
    try testing.expectEqualStrings("", impact.pages[1].via);

    try testing.expectEqual(@as(usize, 1), impact.islands.len);
    const latest = impact.islands[0];
    try testing.expectEqualStrings("latest", latest.key);
    try testing.expect(!latest.dynamic);
    try testing.expectEqual(Reads.query, latest.reads);
    try testing.expectEqual(@as(usize, 2), latest.placed.len);
    try testing.expectEqualStrings("/nested", latest.placed[0].route);
    try testing.expect(!latest.placed[0].prerendered);
    try testing.expectEqualStrings("/posts/:slug", latest.placed[1].route);
    try testing.expect(latest.placed[1].prerendered);
    try testing.expectEqual(@as(usize, 1), latest.inside.len);
    try testing.expectEqualStrings("outer", latest.inside[0]);

    const notes = try of(arena, theme, "note");
    try testing.expectEqual(@as(usize, 1), notes.pages.len);
    try testing.expectEqualStrings("/", notes.pages[0].route);
    try testing.expectEqualStrings("", notes.pages[0].via);

    const nothing = try of(arena, theme, "page");
    try testing.expectEqual(@as(usize, 0), nothing.pages.len);
    try testing.expectEqual(@as(usize, 0), nothing.islands.len);
}

test "the pending budget refuses, the callee set keeps each template once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pending: std.ArrayList([]const ast.Node) = .empty;
    const nodes = [_]ast.Node{.{ .text = "x" }};

    try push(arena, &pending, &.{});
    try testing.expectEqual(@as(usize, 0), pending.items.len);

    for (0..pending_max) |_| {
        try push(arena, &pending, &nodes);
    }

    try testing.expectError(error.TooManyPending, push(arena, &pending, &nodes));

    var callees: std.ArrayList(u32) = .empty;
    try note(arena, &callees, 3);
    try note(arena, &callees, 3);
    try note(arena, &callees, 5);
    try testing.expectEqual(@as(usize, 2), callees.items.len);
}
