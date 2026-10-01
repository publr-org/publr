//! The template engine: an app of `.publr` templates read into a tree, with the route
//! table its `content/` tree declares and the islands its call sites declare, rendered
//! against a context the host supplies. Pure: no database, no HTTP.

const std = @import("std");
pub const ast = @import("template/ast.zig");
pub const compile = @import("template/compile.zig");
pub const render = @import("template/render.zig");
pub const routes = @import("template/routes.zig");
pub const impact = @import("template/impact.zig");
pub const imports = @import("template/imports.zig");

pub const Template = ast.Template;
pub const Options = compile.Options;
pub const File = compile.File;
pub const PjsxComponent = compile.PjsxComponent;
pub const PjsxProp = compile.PjsxProp;
pub const Prop = render.Prop;
pub const Renderer = render.Renderer;
pub const PjsxRender = render.PjsxRender;
pub const Route = routes.Route;
pub const RouteKind = routes.RouteKind;
pub const Match = routes.Match;
pub const route_pattern = routes.route_pattern;
pub const route_kind = routes.route_kind;
pub const match_pattern = routes.match_pattern;
pub const substitute = routes.substitute;

pub const templates_max: u32 = 512;
pub const source_bytes_max: u32 = 1 << 20;
pub const islands_max: u32 = compile.islands_max;
pub const props_max: u32 = compile.props_max;
pub const nesting_max: u32 = compile.nesting_max;

pub fn is_source(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".publr") or std.mem.endsWith(u8, path, ".js") or
        (std.mem.endsWith(u8, path, ".ts") and !std.mem.endsWith(u8, path, ".d.ts"));
}

/// One template as the app provides it, before it is read.
pub const Source = struct {
    /// App-relative, forward slashes: "content/posts/[slug].publr".
    rel: []const u8,
    source: []const u8,
    origin: Template.Origin = .app,
};

pub const Island = struct {
    /// The fragment's name under /_islands/: "<component>" or "<component>-<props hash>".
    key: []const u8,
    template: u32,
    /// The call site's literal props.
    props: []const Prop,
    /// Rendered per request; else built once to a file and shared.
    dynamic: bool,
    /// How long a consumer may reuse the fragment; 0 revalidates every time.
    max_age: u32,
};

pub const LoadError = error{ NoPages, Unsupported, TooManyTemplates, SourceTooLong } ||
    std.mem.Allocator.Error || std.Io.Writer.Error;

/// The loaded app. Everything in it lives in `arena`; `deinit` frees it all.
pub const Program = struct {
    arena_state: std.heap.ArenaAllocator,
    templates: []Template,
    /// Static before dynamic before catch-all, then by pattern.
    routes: []const Route,
    islands: []const Island,
    /// content/404.publr, rendered for every unmatched path.
    error_404: ?u32,
    /// Every utility class the templates name, sorted, once each.
    classes: []const []const u8,
    options: Options,

    pub fn deinit(program: *Program) void {
        program.arena_state.deinit();
    }

    pub fn arena(program: *Program) std.mem.Allocator {
        return program.arena_state.allocator();
    }

    /// The template at this app-relative path, if any.
    pub fn find(program: *const Program, rel: []const u8) ?u32 {
        std.debug.assert(rel.len > 0);
        std.debug.assert(program.templates.len <= templates_max);

        for (program.templates, 0..) |template, index| {
            if (std.mem.eql(u8, template.rel, rel)) {
                return @intCast(index);
            }
        }

        return null;
    }

    pub fn find_island(program: *const Program, key: []const u8) ?*const Island {
        std.debug.assert(program.islands.len <= islands_max);

        for (program.islands) |*island| {
            if (std.mem.eql(u8, island.key, key)) {
                return island;
            }
        }

        return null;
    }

    /// The first route matching `path`, in table order: literal segments match
    /// literally, `:name` any non-empty segment, `*` the rest.
    pub fn match(program: *const Program, path: []const u8) ?Match {
        std.debug.assert(program.routes.len <= templates_max);

        for (program.routes) |*route| {
            if (match_pattern(route.pattern, path)) |slug| {
                return .{ .route = route, .slug = slug };
            }
        }

        return null;
    }
};

/// Where a refusal's message goes: the caller's allocator, and the message naming the
/// template and the construct once `load` has refused.
pub const Diagnostic = struct { arena: std.mem.Allocator, message: []const u8 = "" };

/// Reads every source, compiles them all, and builds the tables. `sources` and
/// everything they point at are copied into the app's own arena.
pub fn load(
    gpa: std.mem.Allocator,
    sources: []const Source,
    options: Options,
    diagnostic: *Diagnostic,
) LoadError!*Program {
    if (options.pjsx.len > templates_max) {
        return error.TooManyTemplates;
    }

    if (sources.len > templates_max) {
        diagnostic.message = "more templates than an app may hold";

        return error.TooManyTemplates;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const templates = try copy_sources(arena, sources, diagnostic);
    var context: compile.Context = .{ .arena = arena, .templates = templates, .options = options };

    for (templates, 0..) |_, index| {
        context.compile(@intCast(index)) catch |err| {
            if (err == error.Unsupported) {
                diagnostic.message = try diagnostic.arena.dupe(u8, context.failure);
            }

            return err;
        };
    }

    // Everything the app's arena will hold is allocated before the arena's state is
    // copied into the app: a copy taken mid-initializer would not know the chunks the
    // later allocations add, and `deinit` would leak them.
    const table = try route_table(arena, templates);

    if (table.routes.len == 0) {
        diagnostic.message = "no routable content/*.publr pages in the app";
        return error.NoPages;
    }

    const islands = try islands_of(arena, context.islands.items);
    const classes = try classes_of(arena, templates);
    const program = try gpa.create(Program);

    program.* = .{
        .arena_state = arena_state,
        .templates = templates,
        .routes = table.routes,
        .islands = islands,
        .error_404 = table.error_404,
        .classes = classes,
        .options = options,
    };

    std.debug.assert(program.templates.len == sources.len);

    return program;
}

fn copy_sources(
    arena: std.mem.Allocator,
    sources: []const Source,
    diagnostic: *Diagnostic,
) LoadError![]Template {
    std.debug.assert(sources.len <= templates_max);

    const templates = try arena.alloc(Template, sources.len);
    var has_page = false;

    for (sources, templates) |item, *template| {
        if (item.rel.len == 0 or item.rel.len > routes.pattern_len_max - 32 or
            !is_source(item.rel) or item.rel[0] == '/')
        {
            diagnostic.message = "template paths must be relative .publr paths " ++
                "within the route limit";
            return error.Unsupported;
        }
        // One leading `../` names a template outside the app, by its folder and path.
        const outside = std.mem.startsWith(u8, item.rel, imports.outside_prefix);
        const inside = if (outside) item.rel[imports.outside_prefix.len..] else item.rel;
        var segments = std.mem.splitScalar(u8, inside, '/');
        while (segments.next()) |segment| {
            if (segment.len == 0 or std.mem.eql(u8, segment, ".") or
                std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".publr") or
                (outside and std.mem.indexOfScalar(u8, inside, '/') == null))
            {
                diagnostic.message = "template paths must have nonempty names " ++
                    "without . or .. segments, but for one leading ../<folder>/";
                return error.Unsupported;
            }
        }
        if (item.source.len > source_bytes_max) {
            diagnostic.message = try std.fmt.allocPrint(
                diagnostic.arena,
                "{s} is longer than a template may be",
                .{item.rel},
            );

            return error.SourceTooLong;
        }

        const is_module = !std.mem.endsWith(u8, item.rel, ".publr");
        const is_page = !is_module and std.mem.startsWith(u8, item.rel, "content/");
        has_page = has_page or is_page;
        template.* = .{
            .rel = try arena.dupe(u8, item.rel),
            .source = try arena.dupe(u8, item.source),
            .kind = if (is_module) .module else if (is_page) .page else .layout,
            .origin = item.origin,
        };
    }

    std.mem.sort(Template, templates, {}, template_less_than);

    if (!has_page) {
        diagnostic.message = "no content/*.publr in the app";

        return error.NoPages;
    }

    return templates;
}

const RouteTable = struct { routes: []const Route, error_404: ?u32 };

fn route_table(arena: std.mem.Allocator, templates: []const Template) LoadError!RouteTable {
    std.debug.assert(templates.len <= templates_max);

    var list: std.ArrayList(Route) = .empty;
    var error_404: ?u32 = null;

    for (templates, 0..) |template, index| {
        if (template.kind != .page) {
            continue;
        }

        if (is_error_page(template.rel)) {
            if (std.mem.endsWith(u8, template.rel, "404.publr")) {
                error_404 = @intCast(index);
            }

            continue;
        }

        const pattern = try route_pattern(arena, template.rel);

        try list.append(arena, .{
            .pattern = pattern,
            .kind = route_kind(pattern),
            .template = @intCast(index),
            .live = template.dynamic,
        });
    }

    std.mem.sort(Route, list.items, {}, routes.route_less_than);

    return .{ .routes = list.items, .error_404 = error_404 };
}

fn islands_of(arena: std.mem.Allocator, uses: []const compile.IslandUse) LoadError![]const Island {
    std.debug.assert(uses.len <= islands_max);

    const islands = try arena.alloc(Island, uses.len);

    for (uses, islands) |use, *island| {
        const props = try arena.alloc(Prop, use.props.len);

        for (use.props, props) |arg, *prop| {
            prop.* = .{ .name = arg.name, .value = arg.value.literal };
        }

        island.* = .{
            .key = use.key,
            .template = use.template,
            .props = props,
            .dynamic = use.dynamic,
            .max_age = use.max_age,
        };
    }

    return islands;
}

/// Every class the templates name, sorted, once each: the stylesheet's input.
fn classes_of(arena: std.mem.Allocator, templates: []const Template) LoadError![]const []const u8 {
    std.debug.assert(templates.len <= templates_max);

    var all: std.ArrayList([]const u8) = .empty;

    for (templates) |template| {
        try all.appendSlice(arena, template.classes);
    }

    std.mem.sort([]const u8, all.items, {}, compile.string_less_than);

    var classes: std.ArrayList([]const u8) = .empty;
    var previous: []const u8 = "";

    for (all.items) |class| {
        if (std.mem.eql(u8, class, previous)) {
            continue;
        }

        try classes.append(arena, class);
        previous = class;
    }

    std.debug.assert(classes.items.len <= all.items.len);

    return classes.items;
}

fn template_less_than(_: void, left: Template, right: Template) bool {
    return std.mem.lessThan(u8, left.rel, right.rel);
}

fn is_error_page(rel: []const u8) bool {
    std.debug.assert(rel.len > 0);

    const basename = rel[(std.mem.lastIndexOfScalar(u8, rel, '/') orelse 0) + 1 ..];

    return std.mem.eql(u8, basename, "404.publr") or std.mem.eql(u8, basename, "500.publr");
}

// ---- tests -------------------------------------------------------------------------

const testing = std.testing;

test {
    testing.refAllDecls(@This());
    _ = @import("template/blocks.zig");
    _ = @import("template/components.zig");
    _ = @import("template/expression.zig");
    _ = @import("template/frontmatter.zig");
    _ = @import("template/markup.zig");
    _ = @import("template/javascript/vm.zig");
}

test "JavaScript renders the seeded marketing components without client code" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{
        source("components/dots.publr", @embedFile("template/javascript/fixtures/DotField.publr")),
        source("components/orbit.publr", @embedFile("template/javascript/fixtures/Orbit.publr")),
        source(
            "components/graph.publr",
            @embedFile("template/javascript/fixtures/DependencyGraph.publr"),
        ),
        source("content/index.publr",
            \\---
            \\import Dots from '../components/dots.publr';
            \\import Orbit from '../components/orbit.publr';
            \\import Graph from '../components/graph.publr';
            \\---
            \\<Dots seed={7919} corner="right" /><Orbit class="hero" /><Graph />
        ),
    }, .{});
    defer destroy(program);
    const ctx: TestContext = .{ .arena = arena };
    const index = program.find("content/index.publr").?;
    const first = try render_test(arena, program, index, &ctx);
    const second = try render_test(arena, program, index, &ctx);
    try testing.expectEqualStrings(first, second);
    try testing.expect(contains(first, "viewBox=\"0 0 672 336\""));
    try testing.expect(contains(first, "cx=\"418.26\" cy=\"348.98\""));
    try testing.expect(contains(first, "2 of 4 pages updated"));
    try testing.expect(!contains(first, "<script"));
    try testing.expect(!program.templates[index].dynamic);
    try testing.expect(program.templates[index].javascript == null);
}

test "JavaScript keeps lexical helpers, operand semantics, structured props and escaping" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{source("content/index.publr",
        \\---
        \\const rows = [{ text: '<hello>', number: 1.25 }, { text: '&bye', number: 2.5 }];
        \\const hot = new Set([1]);
        \\const label = (index) => hot.has(index) ? 'hot' : 'cold';
        \\---
        \\<svg>{rows.map((row, index) => (
        \\  <text x={row.number} data-state={label(index)}>{row.text}</text>
        \\))}</svg>
        \\<p>{'' || 'fallback'}{false && <b>hidden</b>}</p>
    )}, .{});
    defer destroy(program);
    const ctx: TestContext = .{ .arena = arena };
    const html = try render_test(arena, program, program.find("content/index.publr").?, &ctx);
    try testing.expect(contains(html, "<text x=\"1.25\" data-state=\"cold\">&lt;hello&gt;</text>"));
    try testing.expect(contains(html, "<text x=\"2.5\" data-state=\"hot\">&amp;bye</text>"));
    try testing.expect(contains(html, "<p>fallback</p>"));
}

test "JavaScript data reads use the host and retain conservative impact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{source("content/index.publr",
        \\---
        \\const type = 'post';
        \\const posts = Publr.build.getCollection({ type });
        \\const titles = posts.map(post => post.title.toUpperCase());
        \\const rows = posts[0].data.rows.map(row => row.data.content.toUpperCase());
        \\---
        \\<ul>{titles.map(title => <li>{title}</li>)}</ul>
        \\<p>{rows.join(',')}</p>
    )}, .{});
    defer destroy(program);
    var templates: std.ArrayList([]const u8) = .empty;
    const ctx: TestContext = .{ .arena = arena, .templates = &templates };
    const html = try render_test(arena, program, program.find("content/index.publr").?, &ctx);
    try testing.expect(contains(html, "SECOND &lt;POST&gt;"));
    try testing.expect(contains(html, "ALPHA,BETA"));
    try testing.expectEqual(@as(usize, 1), templates.items.len);
    try testing.expectEqual(@as(usize, 1), (try impact.of(arena, program, "post")).pages.len);
}

test "JavaScript passes typed props between native and computed components" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{
        source(
            "content/index.publr",
            fenced("import Card from '../components/card.publr';", "<Card count={7} />"),
        ),
        source("components/card.publr",
            \\---
            \\import Label from './label.publr';
            \\const {count} = props;
            \\const values = [count, count + 1];
            \\---
            \\<p>{typeof count}:{values.map(number => <Label text={`#${number}`} />)}</p>
        ),
        source("components/label.publr", "<b>{props.text}</b>"),
    }, .{});
    defer destroy(program);
    const ctx: TestContext = .{ .arena = arena };
    const html = try render_test(arena, program, program.find("content/index.publr").?, &ctx);
    try testing.expect(contains(html, "<p>number:<b>#7</b><b>#8</b></p>"));
}

test "static JavaScript cannot reach request data through an alias" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{source("content/index.publr",
        \\---
        \\const api = Publr;
        \\const email = api.request.session;
        \\---
        \\<p>{email}</p>
    )}, .{});
    defer destroy(program);
    const ctx: TestContext = .{ .arena = arena, .email = "private@example.com" };
    try testing.expectError(
        error.StaticRequestAccess,
        render_test(arena, program, program.find("content/index.publr").?, &ctx),
    );
}

test "helper modules preserve live bindings and track transitive imports" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{
        source(
            "lib/counter.ts",
            "export let count: number = 0; export function increment() { count++; }",
        ),
        source("lib/helpers.js", "export { count, increment } from './counter.ts';"),
        source("content/index.publr",
            \\---
            \\import {count, increment} from '../lib/helpers.js';
            \\increment();
            \\---
            \\<p>{count}</p>
        ),
    }, .{});
    defer destroy(program);
    var templates: std.ArrayList([]const u8) = .empty;
    const ctx: TestContext = .{ .arena = arena, .templates = &templates };
    const index = program.find("content/index.publr").?;
    const html = try render_test(arena, program, index, &ctx);
    try testing.expect(contains(html, "<p>1</p>"));
    try testing.expectEqual(@as(usize, 3), templates.items.len);
    try testing.expectEqualStrings(html, try render_test(arena, program, index, &ctx));
}

test "JavaScript expression boundaries include regex, comments and nested templates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const markup = "<p>{Math.round(1.25)}|{/}/.test('}') ? 'yes' : 'no'}|" ++
        "{`outer ${`inner ${2}`}`}|{1 /* } */ + 2}{/* } */}</p>";
    const program = try load_test(&.{source("content/index.publr", markup)}, .{});
    defer destroy(program);
    const html = try render_test(arena, program, program.routes[0].template, &.{ .arena = arena });
    try testing.expectEqualStrings("<p>1|yes|outer inner 2|3</p>", html);
}

test "JavaScript entry props reach native components" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{
        source("content/index.publr",
            \\---
            \\import Card from '../components/card.publr';
            \\const posts = Publr.build.getCollection({ type: 'post' });
            \\const cards = posts.map(item => <Card item={item} note="!" />);
            \\---
            \\<ul>{cards}</ul>
        ),
        card_component,
    }, .{});
    defer destroy(program);
    const html = try render_test(arena, program, program.routes[0].template, &.{ .arena = arena });
    try testing.expect(contains(html, "Second &lt;post&gt;!"));
}

test "JavaScript entry props keep the entry namespace in computed components" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{
        source("content/index.publr",
            \\---
            \\import Card from '../components/card.publr';
            \\const posts = Publr.build.getCollection({ type: 'post' });
            \\const cards = posts.map(item => <Card item={item} note="!" />);
            \\---
            \\<ul>{cards}</ul>
        ),
        source("components/card.publr", fenced(
            "const item = props.entry.item; const title = item.title.toUpperCase();",
            "<li>{title}</li>",
        )),
    }, .{});
    defer destroy(program);
    const html = try render_test(arena, program, program.routes[0].template, &.{ .arena = arena });
    try testing.expect(contains(html, "SECOND &lt;POST&gt;"));
}

test "JavaScript cannot treat an ordinary object as raw markup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{source("content/index.publr",
        \\---
        \\const untrusted = JSON.parse('{"kind":"text","value":"<script>bad()</script>"}');
        \\---
        \\<p>{untrusted}</p>
    )}, .{});
    defer destroy(program);
    try testing.expectError(
        error.InvalidJavaScriptChild,
        render_test(arena, program, program.routes[0].template, &.{ .arena = arena }),
    );
}

test "JavaScript supports nested conditional declarations in frontmatter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const program = try load_test(&.{source("content/index.dynamic.publr",
        \\---
        \\const who = Publr.request.session;
        \\if (who) {
        \\  if (who.email) {
        \\    const stamp = Publr.request.now();
        \\  }
        \\}
        \\---
        \\<p>{who ? who.email : 'guest'}</p>
    )}, .{});
    defer destroy(program);
    const index = program.routes[0].template;
    const ctx: TestContext = .{ .arena = arena, .live = true, .email = "ada@example.com" };
    try testing.expect(program.templates[index].javascript != null);
    try testing.expectEqualStrings(
        "<p>ada@example.com</p>",
        try render_test(arena, program, index, &ctx),
    );
}

fn load_test(sources: []const Source, options: Options) !*Program {
    std.debug.assert(sources.len > 0);

    var diagnostic: Diagnostic = .{ .arena = testing.allocator };

    return load(testing.allocator, sources, options, &diagnostic) catch |err| {
        defer testing.allocator.free(diagnostic.message);
        std.debug.print("load failed: {s}\n", .{diagnostic.message});

        return err;
    };
}

/// Loads and expects the failure, returning its message (owned by the caller).
fn refuse(sources: []const Source, options: Options) ![]const u8 {
    std.debug.assert(sources.len > 0);

    var diagnostic: Diagnostic = .{ .arena = testing.allocator };

    if (load(testing.allocator, sources, options, &diagnostic)) |program| {
        destroy(program);

        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expectEqual(error.Unsupported, err);

        return diagnostic.message;
    }
}

fn destroy(program: *Program) void {
    program.deinit();
    testing.allocator.destroy(program);
}

/// A stand-in for the site's context: two posts, a signed-in visitor when the test
/// says so, a fixed clock.
pub const TestContext = struct {
    arena: std.mem.Allocator,
    live: bool = false,
    email: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,
    /// Where a page asked to be redirected, when the test wants to see it.
    redirected: ?*?[]const u8 = null,
    /// The signed-in user's custom fields, `<group>.<field>` and its text.
    user_fields: []const [2][]const u8 = &.{},
    /// The operations the render called, when the test wants to see them.
    calls: ?*std.ArrayList([]const u8) = null,
    /// Every template the render went through, when recording.
    templates: ?*std.ArrayList([]const u8) = null,

    pub const Entry = struct {
        id: []const u8,
        type: []const u8 = "post",
        slug: ?[]const u8,
        title: []const u8,
        created_at: []const u8,
        updated_at: []const u8,
        data: Data,
    };
    pub const Data = struct {
        content: []const u8,
        related: []const []const u8 = &.{},
        /// The `rows` repeater: one row per text, read as `row.data.content`.
        rows: []const []const u8 = &.{},

        pub fn javascript_value(data: Data, arena: std.mem.Allocator) !std.json.Value {
            std.debug.assert(data.rows.len <= 65536);
            var rows: std.ArrayList(struct { content: []const u8 }) = .empty;

            for (data.rows) |text| {
                try rows.append(arena, .{ .content = text });
            }

            const text = try std.json.Stringify.valueAlloc(arena, .{
                .content = data.content,
                .excerpt = "an excerpt",
                .related = data.related,
                .rows = rows.items,
            }, .{});
            return (try std.json.parseFromSlice(
                std.json.Value,
                arena,
                text,
                .{ .allocate = .alloc_always },
            )).value;
        }

        pub fn getText(data: Data, key: []const u8) ?[]const u8 {
            std.debug.assert(key.len > 0);

            if (std.mem.eql(u8, key, "content")) {
                return data.content;
            }

            if (std.mem.eql(u8, key, "excerpt")) {
                return "an excerpt";
            }

            return null;
        }

        pub fn getIds(data: Data, arena: std.mem.Allocator, key: []const u8) ![]const []const u8 {
            _ = arena;

            std.debug.assert(key.len > 0);

            return if (std.mem.eql(u8, key, "related")) data.related else &.{};
        }

        pub fn getItems(data: Data, arena: std.mem.Allocator, key: []const u8) ![]const Entry {
            std.debug.assert(key.len > 0);

            if (!std.mem.eql(u8, key, "rows")) {
                return &.{};
            }

            const items = try arena.alloc(Entry, data.rows.len);

            for (data.rows, 0..) |text, index| {
                items[index] = .{
                    .id = "",
                    .type = "",
                    .slug = null,
                    .title = "",
                    .created_at = "",
                    .updated_at = "",
                    .data = .{ .content = text },
                };
            }

            return items;
        }
    };
    pub const Session = struct { email: ?[]const u8 = null };
    pub const QueryOptions = struct { limit: ?u32 = null, offset: ?u32 = null };

    const posts = [_]Entry{
        .{
            .id = "p2",
            .slug = "second",
            .title = "Second <post>",
            .created_at = "2026-02-02",
            .updated_at = "2026-02-03",
            .data = .{
                .content = "<p>Two</p>",
                .related = &.{ "p1", "gone", "p2" },
                .rows = &.{ "alpha", "beta" },
            },
        },
        .{
            .id = "p1",
            .slug = "first",
            .title = "First",
            .created_at = "2026-01-01",
            .updated_at = "2026-01-01",
            .data = .{ .content = "<p>One</p>" },
        },
    };

    pub fn prerender(ctx: *const TestContext) TestContext {
        return .{ .arena = ctx.arena, .slug = ctx.slug, .templates = ctx.templates };
    }

    pub fn stale(ctx: *const TestContext) TestContext {
        return .{ .arena = ctx.arena, .slug = ctx.slug };
    }

    pub fn head_assets(ctx: *const TestContext, writer: *std.Io.Writer) !void {
        _ = ctx;

        try writer.writeAll("<style>/* css */</style>");
    }

    pub fn asset_url(ctx: *const TestContext, writer: *std.Io.Writer, path: []const u8) !void {
        _ = ctx;

        try writer.print("{s}?v=test", .{path});
    }

    pub fn param(ctx: *const TestContext, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, name, "slug")) ctx.slug else null;
    }

    pub fn entry(ctx: *const TestContext, type_id: []const u8, slug: []const u8) !Entry {
        _ = ctx;

        std.debug.assert(slug.len > 0);

        if (!std.mem.eql(u8, type_id, "post")) {
            return error.UnknownContentType;
        }

        for (posts) |post| {
            if (std.mem.eql(u8, post.slug.?, slug)) {
                return post;
            }
        }

        return error.EntryNotFound;
    }

    pub fn query(
        ctx: *const TestContext,
        type_id: []const u8,
        options: QueryOptions,
    ) ![]const Entry {
        _ = ctx;

        std.debug.assert(type_id.len > 0);

        if (!std.mem.eql(u8, type_id, "post")) {
            return error.UnknownContentType;
        }

        const end = @min(posts.len, options.limit orelse posts.len);

        return posts[0..end];
    }

    pub fn references(ctx: *const TestContext, ids: []const []const u8) ![]const Entry {
        var found: std.ArrayList(Entry) = .empty;

        std.debug.assert(ids.len <= 8);

        for (ids) |id| {
            for (posts) |post| {
                if (std.mem.eql(u8, post.id, id)) {
                    try found.append(ctx.arena, post);
                }
            }
        }

        return found.items;
    }

    pub fn first(ctx: *const TestContext, type_id: []const u8) !Entry {
        _ = ctx;

        std.debug.assert(type_id.len > 0);

        if (!std.mem.eql(u8, type_id, "post")) {
            return error.UnknownContentType;
        }

        return posts[0];
    }

    pub fn reference(ctx: *const TestContext, ids: []const []const u8) !Entry {
        const found = try ctx.references(ids);

        std.debug.assert(ids.len <= 8);

        if (found.len > 0) {
            return found[0];
        }

        return .{
            .id = "",
            .type = "",
            .slug = null,
            .title = "",
            .created_at = "",
            .updated_at = "",
            .data = .{ .content = "" },
        };
    }

    pub fn build_time(ctx: *const TestContext) i64 {
        _ = ctx;

        return 1000;
    }

    pub fn now(ctx: *const TestContext) i64 {
        _ = ctx;

        return 2000;
    }

    pub fn session(ctx: *const TestContext) !Session {
        return .{ .email = ctx.email };
    }

    pub fn header(ctx: *const TestContext, name: []const u8) ?[]const u8 {
        return if (std.mem.eql(u8, name, "user-agent")) ctx.user_agent else null;
    }

    pub fn cookie(ctx: *const TestContext, name: []const u8) ?[]const u8 {
        _ = ctx;

        return if (std.mem.eql(u8, name, "theme")) "dark" else null;
    }

    pub fn random(ctx: *const TestContext, bound: u32) i64 {
        _ = ctx;

        return @intCast(bound - 1);
    }

    pub fn call(ctx: *const TestContext, operation: []const u8) !Entry {
        std.debug.assert(operation.len > 0);

        if (ctx.calls) |calls| {
            try calls.append(ctx.arena, operation);
        }

        return ctx.reference(&.{});
    }

    pub fn user_field(ctx: *const TestContext, path: []const u8) !?[]const u8 {
        std.debug.assert(path.len > 0);

        for (ctx.user_fields) |pair| {
            if (std.mem.eql(u8, pair[0], path)) {
                return pair[1];
            }
        }

        return null;
    }

    pub fn redirect(ctx: *const TestContext, path: []const u8) !void {
        std.debug.assert(path.len > 0);

        const slot = ctx.redirected orelse return error.RedirectUnavailable;

        slot.* = path;
    }

    pub fn record_template(ctx: *const TestContext, rel: []const u8) void {
        std.debug.assert(rel.len > 0);

        const list = ctx.templates orelse return;

        list.append(ctx.arena, rel) catch |err| {
            std.debug.print("record_template: {s}\n", .{@errorName(err)});
        };
    }
};

const TestRenderer = Renderer(TestContext);

fn render_test(
    arena: std.mem.Allocator,
    program: *const Program,
    index: u32,
    ctx: *const TestContext,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const renderer: TestRenderer = .{
        .templates = program.templates,
        .pjsx = &.{},
        .arena = arena,
    };

    try renderer.render(&out.writer, index, ctx, .{});

    return out.written();
}

fn contains(page: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, page, needle) != null;
}

fn source(rel: []const u8, text: []const u8) Source {
    return .{ .rel = rel, .source = text };
}

/// A frontmatter of one statement over a body: the shape most test templates take.
fn fenced(comptime statement: []const u8, comptime body: []const u8) []const u8 {
    return "---\n" ++ statement ++ "\n---\n" ++ body;
}

test "an app loads: queries, a loop, set:html, a layout with slot and props, routes; and renders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("content/index.publr", fenced(
            "import Base from '../layouts/base.publr';",
            "<Base><h1>Hi &amp; bye</h1></Base>\n",
        )),
        source("content/posts/[slug].publr",
            \\---
            \\import Base from '../../layouts/base.publr';
            \\const post = Publr.build.getEntry();
            \\const body = post.data.content ?? '';
            \\---
            \\<Base title={post.title}>
            \\  <h1>{post.title}</h1>
            \\  <p data-id={post.id}>{post.updated_at}</p>
            \\  <div class="body prose" set:html={body} />
            \\</Base>
        ),
        source("content/posts/index.publr",
            \\---
            \\import Base from '../../layouts/base.publr';
            \\const posts = Publr.build.getCollection({ limit: 100 });
            \\---
            \\<Base>
            \\  {posts.length === 0 ? (<p>None</p>) : null}
            \\  <ul>
            \\    {posts.map((post) => (
            \\      <li><a href={`/posts/${post.slug ?? ""}`}>{post.title}</a></li>
            \\    ))}
            \\  </ul>
            \\</Base>
        ),
        source("content/404.publr", "<p>lost</p>"),
        source("layouts/base.publr",
            \\---
            \\const ts = Publr.build.now();
            \\---
            \\<!DOCTYPE html>
            \\<html><head><title>{props.title ?? "Site"}</title></head>
            \\<body class="p-4"><main><slot /></main><footer>{ts}</footer></body></html>
        ),
    }, .{});
    defer destroy(program);

    // The route table: static before dynamic, the 404 apart.
    try testing.expectEqual(@as(usize, 3), program.routes.len);
    try testing.expectEqualStrings("/", program.routes[0].pattern);
    try testing.expectEqualStrings("/posts", program.routes[1].pattern);
    try testing.expectEqualStrings("/posts/:slug", program.routes[2].pattern);
    try testing.expectEqual(RouteKind.dynamic, program.routes[2].kind);
    try testing.expect(!program.routes[2].live);
    try testing.expectEqualStrings("content/404.publr", program.templates[program.error_404.?].rel);
    try testing.expectEqual(@as(usize, 0), program.islands.len);
    try testing.expectEqualStrings("body", program.classes[0]);
    try testing.expectEqualStrings("p-4", program.classes[1]);
    try testing.expectEqualStrings("prose", program.classes[2]);

    const layout = program.templates[program.find("layouts/base.publr").?];
    try testing.expectEqual(@as(usize, 1), layout.props.?.len);
    try testing.expectEqualStrings("title", layout.props.?[0]);

    // A post page: the entry by slug, the title escaped, the body raw.
    const single_index = program.routes[2].template;
    const second_ctx: TestContext = .{ .arena = arena, .slug = "second" };
    const single = try render_test(arena, program, single_index, &second_ctx);
    const head = "<!DOCTYPE html>\n<html><head><title>Second &lt;post&gt;</title>" ++
        "<style>/* css */</style></head>";
    try testing.expect(std.mem.startsWith(u8, single, head));
    try testing.expect(contains(single, "<h1>Second &lt;post&gt;</h1>"));
    try testing.expect(contains(single, "<p data-id=\"p2\">2026-02-03</p>"));
    try testing.expect(contains(single, "<div class=\"body prose\"><p>Two</p></div>"));
    try testing.expect(contains(single, "<footer>1970-01-01 00:00:01</footer>"));
    const nope_ctx: TestContext = .{ .arena = arena, .slug = "nope" };
    const missing = render_test(arena, program, single_index, &nope_ctx);
    try testing.expectError(error.EntryNotFound, missing);

    // The listing: the loop, the template literal, the conditional's null arm.
    const listing_index = program.routes[1].template;
    const listing = try render_test(arena, program, listing_index, &.{ .arena = arena });
    try testing.expect(contains(listing, "<title>Site</title>"));
    try testing.expect(!contains(listing, "<p>None</p>"));
    const second_item = "<li><a href=\"/posts/second\">Second &lt;post&gt;</a></li>";
    try testing.expect(contains(listing, second_item));
    try testing.expect(contains(listing, "<li><a href=\"/posts/first\">First</a></li>"));

    const home = try render_test(arena, program, program.routes[0].template, &.{ .arena = arena });
    try testing.expect(contains(home, "<main><h1>Hi &amp; bye</h1></main>"));
}

const greeting_source = source("components/greeting.dynamic.publr",
    \\---
    \\const session = Publr.request.session;
    \\---
    \\{session ? (<b>Hi {session.email ?? ""}</b>) : (<a href="/admin">Sign in</a>)}
);
const latest_source = source("components/latest.publr",
    \\---
    \\const posts = Publr.build.getCollection({ type: 'post', limit: 3 });
    \\---
    \\<h2>{props.heading ?? "Latest"}</h2>
    \\<ul>{posts.map((p) => (<li>{p.title}</li>))}</ul>
    \\<slot />
);
const welcome_source = source("components/welcome.dynamic.publr",
    \\---
    \\const session = Publr.request.session;
    \\const latest = Publr.request.getCollection({ type: 'post', limit: 1 });
    \\---
    \\<p>For {session.email ?? props.fallbackWho ?? "a guest"}:
    \\{latest.map((p) => (<b>{p.title}</b>))}</p>
);

test "references: getReferences follows a field, a component takes an entry, entry.type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("components/card.publr",
            \\---
            \\const item = props.entry.item;
            \\const more = Publr.build.getReferences(item, 'related');
            \\const first = Publr.build.getReference(item, 'related');
            \\const note = props.note ?? '?';
            \\---
            \\<li data-type={item.type}>{item.title}{note}
            \\ ({more.length}/{first.id})</li>
        ),
        source("content/posts/[slug].publr",
            \\---
            \\import Card from '../../components/card.publr';
            \\const post = Publr.build.getEntry();
            \\const related = Publr.build.getReferences(post, 'related');
            \\---
            \\<p>{post.type}</p>
            \\<ul>{related.map((item) => (<Card item={item} note="!" />))}</ul>
        ),
        source("content/index.publr",
            \\---
            \\const home = Publr.build.getEntry({ type: 'post', slug: 'first' });
            \\---
            \\<h1>{home.title}</h1>
        ),
        source("content/notes/[slug].publr",
            \\---
            \\const note = Publr.build.getEntry({ type: 'post' });
            \\---
            \\<h1>{note.title}</h1>
        ),
        source("components/latest.publr",
            \\---
            \\const newest = Publr.build.getEntry({ type: 'post' });
            \\---
            \\<b>{newest.title}</b>
        ),
    }, .{});
    defer destroy(program);

    const card = program.templates[program.find("components/card.publr").?];
    try testing.expectEqual(@as(usize, 2), card.props.?.len);
    try testing.expectEqual(@as(usize, 1), card.entry_props.len);
    try testing.expectEqualStrings("item", card.entry_props[0]);

    // "gone" is left out; "p2" points back at the page's own entry, whose related list
    // is followed one level down by the card.
    const ctx: TestContext = .{ .arena = arena, .slug = "second" };
    const single = program.find("content/posts/[slug].publr").?;
    const page = try render_test(arena, program, single, &ctx);
    try testing.expect(contains(page, "<p>post</p>"));
    try testing.expect(contains(page, "<li data-type=\"post\">First!\n (0/)</li>"));
    try testing.expect(contains(page, "<li data-type=\"post\">Second &lt;post&gt;!\n (2/p1)</li>"));
    try testing.expect(!contains(page, "gone"));

    // A record by type and slug from an index page; another type at a route's slug.
    const home = try render_test(arena, program, program.find("content/index.publr").?, &ctx);
    try testing.expect(contains(home, "<h1>First</h1>"));
    const note_index = program.find("content/notes/[slug].publr").?;
    const note = try render_test(arena, program, note_index, &ctx);
    try testing.expect(contains(note, "<h1>Second &lt;post&gt;</h1>"));

    // A component with no route reads the type's one record.
    const latest = try render_test(arena, program, program.find("components/latest.publr").?, &ctx);
    try testing.expectEqualStrings("<b>Second &lt;post&gt;</b>", latest);
}

test "repeaters: a data field with no fallback is the rows, each read as an entry" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("content/posts/[slug].publr",
            \\---
            \\const post = Publr.build.getEntry();
            \\const rows = post.data.rows;
            \\const none = post.data.missing;
            \\---
            \\<ol>{rows.map((row) => (<li>{row.data.content}</li>))}</ol>
            \\<i>{rows.length}/{none.length}</i>
        ),
    }, .{});
    defer destroy(program);

    const ctx: TestContext = .{ .arena = arena, .slug = "second" };
    const page_index = program.find("content/posts/[slug].publr").?;
    const page = try render_test(arena, program, page_index, &ctx);
    try testing.expectEqualStrings("<ol><li>alpha</li><li>beta</li></ol>\n<i>2/0</i>", page);

    const message = try refuse(&.{
        source("content/posts/[slug].publr",
            \\---
            \\const post = Publr.build.getEntry();
            \\const rows = post.data.rows + 1;
            \\---
            \\<b>{rows.length}</b>
        ),
    }, .{});
    defer testing.allocator.free(message);
    try testing.expect(contains(message, "needs a ?? fallback"));
}

test "islands: dynamic is inferred from Publr.request, `island` defers, dynamic needs dynamic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        greeting_source,
        latest_source,
        welcome_source,
        source("content/index.publr",
            \\---
            \\import Greeting from '../components/greeting.dynamic.publr';
            \\import Latest from '../components/latest.publr';
            \\---
            \\<head></head>
            \\<Greeting dynamic eager><span>…</span></Greeting>
            \\<Latest heading="New" island eager cache="0">more</Latest>
            \\<Latest island eager />
            \\<Latest />
        ),
        source("content/whoami.dynamic.publr",
            \\---
            \\import Greeting from '../components/greeting.dynamic.publr';
            \\const ua = Publr.request.header('user-agent');
            \\---
            \\<head></head><Greeting dynamic /><p>{ua ?? "?"}</p>
        ),
        source("content/posts/index.dynamic.publr",
            \\---
            \\import Greeting from '../../components/greeting.dynamic.publr';
            \\const posts = Publr.build.getCollection({ limit: 5 });
            \\---
            \\<head></head><Greeting dynamic />{posts.map((p) => (<li>{p.title}</li>))}
        ),
        source("content/guest.publr",
            \\---
            \\import Welcome from '../components/welcome.dynamic.publr';
            \\---
            \\<head></head><Welcome dynamic prerender eager fallbackWho="the best person ever" />
        ),
        source("content/stale.publr", fenced(
            "import Latest from '../components/latest.publr';",
            "<head></head><Latest island prerender eager />",
        )),
    }, .{});
    defer destroy(program);

    const greeting = program.templates[program.find(greeting_source.rel).?];
    try testing.expect(greeting.dynamic);
    const latest = program.templates[program.find(latest_source.rel).?];
    try testing.expect(!latest.dynamic);

    // Four islands: greeting, latest with a heading, latest bare, welcome.
    try testing.expectEqual(@as(usize, 4), program.islands.len);
    const greeting_island = program.find_island("greeting").?;
    try testing.expect(greeting_island.dynamic);
    try testing.expectEqual(@as(u32, 0), greeting_island.max_age);
    const bare = program.find_island("latest").?;
    try testing.expect(!bare.dynamic);
    // Opt-out caching: a minute unless told otherwise.
    try testing.expectEqual(@as(u32, 60), bare.max_age);
    const keyed = try compile.island_key(arena, latest_source.rel, &.{"heading=New"});
    const with_heading = program.find_island(keyed).?;
    try testing.expectEqual(@as(u32, 0), with_heading.max_age);
    try testing.expectEqualStrings("heading", with_heading.props[0].name);
    try testing.expectEqualStrings("New", with_heading.props[0].value.?);

    // The home page: a dynamic island's placeholder with the fallback, a static
    // island's placeholder, an embedded render, and the page facts.
    const home_index = program.find("content/index.publr").?;
    const home_template = program.templates[home_index];
    try testing.expect(!home_template.dynamic);
    try testing.expect(home_template.page_islands());
    try testing.expectEqual(@as(usize, 2), home_template.static_island_keys.len);
    try testing.expectEqualStrings("greeting", home_template.dynamic_eager_keys[0]);
    const home = try render_test(arena, program, home_index, &.{ .arena = arena });
    const placeholder = "<publr-island src=\"/_islands/greeting\" credentials>" ++
        "<span>…</span></publr-island>";
    try testing.expect(contains(home, placeholder));
    try testing.expect(contains(home, "\">more</publr-island>"));
    try testing.expect(contains(home, "<publr-island src=\"/_islands/latest\"></publr-island>"));
    const embedded = "<h2>Latest</h2>\n<ul><li>Second &lt;post&gt;</li><li>First</li></ul>";
    try testing.expect(contains(home, embedded));
    const styles = std.mem.count(u8, home, "<style>/* css */</style></head>");
    try testing.expectEqual(@as(usize, 1), styles);
    // Rendered live, the dynamic island is flattened into the page.
    const live_ctx: TestContext = .{ .arena = arena, .live = true, .email = "a@example.com" };
    const home_live = try render_test(arena, program, home_index, &live_ctx);
    try testing.expect(!contains(home_live, "/_islands/greeting"));
    try testing.expect(contains(home_live, "<b>Hi a@example.com</b>"));

    // A live page flattens its dynamic islands: no placeholders.
    const whoami_index = program.find("content/whoami.dynamic.publr").?;
    try testing.expect(program.templates[whoami_index].dynamic);
    try testing.expect(!program.templates[whoami_index].page_islands());
    const browser_ctx: TestContext = .{ .arena = arena, .live = true, .user_agent = "TestBrowser" };
    const whoami = try render_test(arena, program, whoami_index, &browser_ctx);
    try testing.expect(contains(whoami, "<a href=\"/admin\">Sign in</a><p>TestBrowser</p>"));

    // `.dynamic.publr`: dynamic although it reads only Publr.build; its route is the
    // plain `/posts`, and it is live.
    for (program.routes) |route| {
        if (std.mem.eql(u8, route.pattern, "/posts")) {
            try testing.expect(route.live);
            const rel = program.templates[route.template].rel;
            try testing.expectEqualStrings("content/posts/index.dynamic.publr", rel);
        }
    }

    // `prerender`: the build-time render is the placeholder, the same props in hand;
    // the component decides the precedence.
    const guest_index = program.find("content/guest.publr").?;
    const guest = try render_test(arena, program, guest_index, &.{ .arena = arena });
    const prerendered = "credentials prerendered><p>For the best person ever:\n" ++
        "<b>Second &lt;post&gt;</b></p></publr-island>";
    try testing.expect(contains(guest, prerendered));
    const who = "fallbackWho=the best person ever";
    const welcome_key = try compile.island_key(arena, welcome_source.rel, &.{who});
    const guest_keys = program.templates[guest_index].dynamic_idle_keys;
    try testing.expectEqualStrings(guest_keys[0], welcome_key);
    const me_ctx: TestContext = .{ .arena = arena, .live = true, .email = "me@example.com" };
    const guest_live = try render_test(arena, program, guest_index, &me_ctx);
    try testing.expect(contains(guest_live, "<p>For me@example.com:\n"));

    // `prerender` on a static island: the build's own copy of the fragment through
    // `stale()`, which records nothing, and nothing on screen waits.
    const stale_index = program.find("content/stale.publr").?;
    var recorded: std.ArrayList([]const u8) = .empty;
    const stale_ctx: TestContext = .{ .arena = arena, .templates = &recorded };
    const stale = try render_test(arena, program, stale_index, &stale_ctx);
    const stale_copy = "<publr-island src=\"/_islands/latest\" prerendered><h2>Latest</h2>";
    try testing.expect(contains(stale, stale_copy));
    try testing.expectEqualStrings("latest", program.templates[stale_index].static_idle_keys[0]);
    // The page itself, not the island's template.
    try testing.expectEqual(@as(usize, 1), recorded.items.len);
    try testing.expectEqualStrings("content/stale.publr", recorded.items[0]);
}

const Refusal = struct { sources: []const Source, message: []const u8 };

const index_page = source("content/index.publr", "");
const latest_component = source(
    "components/latest.publr",
    fenced("const posts = Publr.build.getCollection({ type: 'post' });", "{posts.length}"),
);
const greeting_component = source(
    "components/greeting.dynamic.publr",
    fenced("const who = Publr.request.session;", "{who.email ?? \"\"}"),
);
const latest_import = "import Latest from '../components/latest.publr';";
const greeting_import = "import Greeting from '../components/greeting.dynamic.publr';";
const posts_query = "const posts = Publr.build.getCollection({ type: 'post' });";

const dynamic_placement = "content/oops.publr: components/greeting.dynamic.publr is dynamic, " ++
    "so it renders per request wherever it is placed. Say so here: <Greeting dynamic />";

const refusals = [_]Refusal{
    .{
        .sources = &.{source("content/index.publr", "<img src=\"/_app/logo.svg\" />")},
        .message = "content/index.publr: /_app/logo.svg: /_app/ holds only what Publr " ++
            "generates; a file in public/ is served at its own path under the app's mount",
    },
    .{
        .sources = &.{
            source("components/fresh.dynamic.publr", fenced(posts_query, "<b>{posts.length}</b>")),
            source("content/uses.publr", fenced(
                "import Fresh from '../components/fresh.dynamic.publr';",
                "<Fresh dynamic dynamic-if=\"signedIn\" />",
            )),
        },
        .message = "content/uses.publr: <Fresh dynamic dynamic-if> — use one: dynamic fetches " ++
            "it on every view, dynamic-if only when its condition holds",
    },
    .{
        .sources = &.{
            source("components/fresh.dynamic.publr", fenced(posts_query, "<b>{posts.length}</b>")),
            source("content/uses.publr", fenced(
                "import Fresh from '../components/fresh.dynamic.publr';",
                "<Fresh dynamic-if={signedIn} />",
            )),
        },
        .message = "content/uses.publr: <Fresh dynamic-if={…}> — the condition is decided in " ++
            "the browser, on each view: name one, dynamic-if=\"signedIn\", registered with " ++
            "Publr.islands.condition",
    },
    .{
        .sources = &.{
            source("components/fresh.dynamic.publr", fenced(posts_query, "<b>{posts.length}</b>")),
            source("content/uses.publr", fenced(
                "import Fresh from '../components/fresh.dynamic.publr';",
                "<Fresh dynamic-if=\"signed-in\" />",
            )),
        },
        .message = "content/uses.publr: <Fresh dynamic-if=\"signed-in\"> — a condition's name " ++
            "is a letter, then letters, digits or _",
    },
    .{
        .sources = &.{
            source("content/index.publr", fenced("const posts = Publr.build.getCollection();", "")),
        },
        .message = "content/index.publr: getCollection() needs a collection directory " ++
            "(content/<type>s/index.publr) or a type option",
    },
    .{
        .sources = &.{
            source("content/index.publr", fenced("const posts = Publr.getCollection();", "")),
        },
        .message = "content/index.publr: Publr.* is namespaced by when the answer is known: " ++
            "Publr.build.* or Publr.request.*, not Publr.getCollection()",
    },
    .{
        .sources = &.{
            index_page,
            source("layouts/base.publr", fenced("const ts = Date.now();", "")),
        },
        .message = "layouts/base.publr: Date.now() does not say when: write Publr.build.now() " ++
            "or Publr.request.now()",
    },
    .{
        .sources = &.{source("content/visit.publr", fenced("const ts = Publr.request.now();", ""))},
        .message = "content/visit.publr reads the dynamic API (Publr.request), so it is dynamic " ++
            "and its name has to say so. Rename it to visit.dynamic.publr",
    },
    .{
        .sources = &.{
            source("content/posts/[slug].publr", fenced("const who = Publr.request.session;", "")),
        },
        .message = "content/posts/[slug].publr reads the dynamic API (Publr.request), so it is " ++
            "dynamic and its name has to say so. Rename it to [slug].dynamic.publr",
    },
    .{
        .sources = &.{
            index_page,
            source("layouts/base.publr", fenced("const who = Publr.build.session;", "")),
        },
        .message = "layouts/base.publr: Publr.build.session — who is signed in is only known " ++
            "per request: Publr.request.session",
    },
    .{
        .sources = &.{ index_page, source(
            "components/mixed.dynamic.publr",
            fenced("const who = Publr.request.session;\n" ++ posts_query, ""),
        ) },
        .message = "Template components/mixed.dynamic.publr is using the dynamic API " ++
            "(Publr.request), so it renders per request. Read everything through the " ++
            "dynamic API: Publr.request.getCollection({ type: 'post' })",
    },
    .{
        .sources = &.{ index_page, source(
            "components/x.publr",
            fenced("const posts = Publr.build.getCollection({ limit: 3 });", ""),
        ) },
        .message = "components/x.publr: a component has no position in content/ — name the " ++
            "type: getCollection({ type: 'post' })",
    },
    .{
        .sources = &.{
            source("content/[slug].publr", fenced("const slug = Astro.params.slug;", "")),
        },
        .message = "content/[slug].publr: the Publr format has no Astro vocabulary: " ++
            "const slug = Astro.params.slug;",
    },
    .{
        .sources = &.{source("content/index.publr", "<p>{nope}</p>")},
        .message = "content/index.publr: `nope` is not declared",
    },
    .{
        .sources = &.{source("content/index.publr", "<p><slot /></p>")},
        .message = "content/index.publr: <slot /> belongs in a layout or component, not a page",
    },
    .{
        .sources = &.{source("content/index.publr", "<Base></Base>")},
        .message = "content/index.publr: <Base> is not imported",
    },
    .{
        .sources = &.{source("content/index.publr", "<div><span></div>")},
        .message = "content/index.publr: </div> closes an open <span>",
    },
    .{
        .sources = &.{
            source("content/index.publr", fenced("import Base from '../layouts/nope.publr';", "")),
        },
        .message = "content/index.publr: import of ../layouts/nope.publr — no such template " ++
            "(layouts/nope.publr)",
    },
    // Islands.
    .{
        .sources = &.{
            greeting_component,
            source("content/oops.publr", fenced(greeting_import, "<Greeting />")),
        },
        .message = dynamic_placement,
    },
    .{
        .sources = &.{
            greeting_component,
            source("content/oops.publr", fenced(greeting_import, "<Greeting island />")),
        },
        .message = dynamic_placement,
    },
    .{
        .sources = &.{
            latest_component,
            source("content/oops.publr", fenced(latest_import, "<Latest dynamic />")),
        },
        .message = "content/oops.publr: <Latest dynamic> — components/latest.publr is static, " ++
            "so it is a choice: <Latest /> renders it into this page, <Latest island /> " ++
            "makes it a fragment of its own",
    },
    .{
        .sources = &.{
            source("components/latest.publr", fenced(
                posts_query,
                "{props.heading ?? \"\"}{posts.length}",
            )),
            source("content/oops.publr", fenced(
                latest_import ++ "\n" ++ posts_query,
                "{posts.map((p) => (<Latest heading={p.title} island />))}",
            )),
        },
        .message = "content/oops.publr: <Latest> — island props must be string literals: the " ++
            "fragment is built once and shared by every page that names it",
    },
    .{
        .sources = &.{
            latest_component,
            source("content/oops.publr", fenced(latest_import, "<Latest prerender />")),
        },
        .message = "content/oops.publr: <Latest prerender> only means something on an island: " ++
            "an embedded component is rendered at build already",
    },
    .{
        .sources = &.{
            source("components/welcome.dynamic.publr", fenced(
                "const who = Publr.request.session;",
                "{who.email ?? \"\"}",
            )),
            source("content/oops.publr", fenced(
                "import Welcome from '../components/welcome.dynamic.publr';",
                "<Welcome dynamic prerender>a fallback</Welcome>",
            )),
        },
        .message = "content/oops.publr: <Welcome prerender>: a fallback would replace the whole " ++
            "prerender — give the component a prop for what the build cannot know instead",
    },
    .{
        .sources = &.{
            source("components/kidded.dynamic.publr", fenced(
                "const session = Publr.request.session;",
                "<b>{session.email ?? \"\"}</b><slot />",
            )),
            index_page,
        },
        .message = "components/kidded.dynamic.publr: <slot /> — a dynamic island has no " ++
            "children, only a fallback it replaces; what a call site must supply is a prop",
    },
    .{
        .sources = &.{
            latest_component,
            source("content/oops.publr", fenced(latest_import, "<Latest cache=\"60\" />")),
        },
        .message = "content/oops.publr: <Latest cache> only means something on an island: an " ++
            "embedded component is part of the page",
    },
    .{
        .sources = &.{ latest_component, source(
            "content/oops.publr",
            fenced(latest_import, "<head></head><Latest island cache=\"soon\" />"),
        ) },
        .message = "content/oops.publr: <Latest cache=\"soon\"> — cache takes a number of seconds",
    },
    .{
        .sources = &.{
            latest_component,
            source("content/a.publr", fenced(
                latest_import,
                "<head></head><Latest island cache=\"0\" />",
            )),
            source("content/b.publr", fenced(
                latest_import,
                "<head></head><Latest island cache=\"5\" />",
            )),
        },
        .message = "content/b.publr: <Latest cache=\"5\"> — another call site names the same " ++
            "island with cache=\"0\"; one fragment, one policy",
    },
    .{
        .sources = &.{
            latest_component,
            source("content/headless.publr", fenced(latest_import, "<Latest island />")),
        },
        .message = "Page content/headless.publr has islands but writes no <head> to carry the " ++
            "island loader",
    },
    // `.dynamic` on something that reads nothing is refused, component or page.
    .{
        .sources = &.{
            source("components/pure.dynamic.publr", "---\n---\n<b>{props.who ?? \"?\"}</b>"),
            index_page,
        },
        .message = "components/pure.dynamic.publr reads nothing, so every render is the same " ++
            "bytes — `.dynamic` would make it uncacheable for no gain. Rename it to pure.publr",
    },
    .{
        .sources = &.{
            source("content/still.dynamic.publr", "---\n---\n<head></head><p>constant</p>"),
        },
        .message = "content/still.dynamic.publr reads nothing, so every render is the same " ++
            "bytes — `.dynamic` would make it uncacheable for no gain. Rename it to still.publr",
    },
    // A component that reads only the store may be `.dynamic`, and the call site has
    // to agree.
    .{
        .sources = &.{
            source("components/fresh.dynamic.publr", fenced(posts_query, "<b>{posts.length}</b>")),
            source("content/wrong.publr", fenced(
                "import Fresh from '../components/fresh.dynamic.publr';",
                "<head></head><Fresh island />",
            )),
        },
        .message = "content/wrong.publr: components/fresh.dynamic.publr is dynamic, so it " ++
            "renders per request wherever it is placed. Say so here: <Fresh dynamic />",
    },
    // Entry props: declared in the frontmatter, passed as entries at every call site.
    .{
        .sources = &.{ card_component, source("content/posts/[slug].publr", fenced(
            "import Card from '../../components/card.publr';",
            "<Card note=\"!\" />",
        )) },
        .message = "content/posts/[slug].publr: <Card> needs item={…}: components/card.publr " ++
            "reads it as an entry",
    },
    .{
        .sources = &.{ card_component, source("content/posts/[slug].publr", fenced(
            "import Card from '../../components/card.publr';",
            "<Card item=\"first\" />",
        )) },
        .message = "content/posts/[slug].publr: <Card item=\"…\"> — item takes an entry, not a " ++
            "string: item={…}",
    },
    .{
        .sources = &.{
            source("components/card.publr", fenced(
                "const item = props.entry.item;",
                "<b>{props.item}</b>",
            )),
            index_page,
        },
        .message = "components/card.publr: props.item is an entry: read it in the frontmatter, " ++
            "const item = props.entry.item;",
    },
    .{
        .sources = &.{
            card_component,
            source("content/posts/[slug].publr",
                \\---
                \\import Card from '../../components/card.publr';
                \\const post = Publr.build.getEntry();
                \\---
                \\<Card item={post} note={post} />
            ),
        },
        .message = "content/posts/[slug].publr: <Card note={…}> passes an entry; note is a " ++
            "string prop (a component declares an entry prop as const note = props.entry.note;)",
    },
    .{
        .sources = &.{source("content/index.publr", fenced(
            "const posts = Publr.build.getCollection({ type: 'post' });\n" ++
                "const more = Publr.build.getReferences(posts, 'related');",
            "<b>{more.length}</b>",
        ))},
        .message = "content/index.publr: getReferences follows a field of an entry; `posts` is " ++
            "a collection",
    },
    .{
        .sources = &.{source("content/index.publr", fenced(
            "const item = props.entry.item;",
            "<b>{item.title}</b>",
        ))},
        .message = "content/index.publr: `props` belong to layouts; pages read `ctx`",
    },
    .{
        .sources = &.{source("content/index.publr", fenced(
            "const go = Publr.build.redirect('/elsewhere');",
            "",
        ))},
        .message = "content/index.publr: Publr.build.redirect() — a build writes files " ++
            "and cannot redirect: Publr.request.redirect()",
    },
    .{
        .sources = &.{
            index_page,
            source("components/go.dynamic.publr", fenced(
                "const go = Publr.request.redirect('/elsewhere');",
                "",
            )),
        },
        .message = "components/go.dynamic.publr: only a page can redirect, " ++
            "not a layout or a component",
    },
    .{
        .sources = &.{source("content/go.dynamic.publr", fenced(
            "const who = Publr.request.session;\nconst go = Publr.request.redirect(who);",
            "",
        ))},
        .message = "content/go.dynamic.publr: redirect() takes a path, a string: " ++
            "empty for no redirect",
    },
    .{
        .sources = &.{source("content/index.publr", fenced(
            "const flag = Publr.build.userField('cloud.welcomed');",
            "",
        ))},
        .message = "content/index.publr: Publr.build.userField() — who is signed in is only " ++
            "known per request: Publr.request.userField()",
    },
    .{
        .sources = &.{source("content/me.dynamic.publr", fenced(
            "const flag = Publr.request.userField('welcomed');",
            "",
        ))},
        .message = "content/me.dynamic.publr: userField() names `<group>.<field>`: welcomed",
    },
    .{
        .sources = &.{source("content/index.publr", fenced(
            "const seen = Publr.build.call('cloud.welcome');",
            "",
        ))},
        .message = "content/index.publr: Publr.build.call() — a build writes files and runs " ++
            "no operation: Publr.request.call()",
    },
    .{
        .sources = &.{source("content/go.dynamic.publr", fenced(
            "const seen = Publr.request.call('welcome');",
            "",
        ))},
        .message = "content/go.dynamic.publr: call() names an operation, " ++
            "`<namespace>.<verb>` or `app.<feature>.<verb>`: welcome",
    },
    .{
        .sources = &.{source("content/go.dynamic.publr", fenced(
            "const seen = Publr.request.call('app.welcome');",
            "",
        ))},
        .message = "content/go.dynamic.publr: call() names an operation, " ++
            "`<namespace>.<verb>` or `app.<feature>.<verb>`: app.welcome",
    },
    .{
        .sources = &.{source("content/go.dynamic.publr", fenced(
            "Publr.request.session;",
            "",
        ))},
        .message = "content/go.dynamic.publr: `Publr.request.session` reads a value and does " ++
            "nothing on its own: name it, const value = Publr.request.session",
    },
    .{
        .sources = &.{source("content/index.publr", fenced(
            "Publr.build.redirect('/elsewhere');",
            "",
        ))},
        .message = "content/index.publr: Publr.build.redirect() — a build writes files " ++
            "and cannot redirect: Publr.request.redirect()",
    },
    .{
        .sources = &.{source("content/go.dynamic.publr", fenced(
            "Publr.go.redirect('/elsewhere');",
            "",
        ))},
        .message = "content/go.dynamic.publr: Publr.* is namespaced by when the answer is " ++
            "known: Publr.build.* or Publr.request.*, not Publr.go.redirect('/elsewhere')",
    },
    .{
        .sources = &.{source("content/go.dynamic.publr", fenced(
            "const who = Publr.request.session;\nif (who) {\n  Publr.request.redirect('/x');",
            "",
        ))},
        .message = "content/go.dynamic.publr: an `if` block in the frontmatter is never " ++
            "closed with `}`",
    },
    .{
        .sources = &.{source("content/go.dynamic.publr", fenced("} else {", ""))},
        .message = "content/go.dynamic.publr: `else` without an `if`",
    },
};

test "redirect: a page answers with the path its expression gives, or renders" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{source("content/login.dynamic.publr",
        \\---
        \\const session = Publr.request.session;
        \\if (session) {
        \\  Publr.request.redirect('/spaces/mine');
        \\}
        \\---
        \\<head></head><p>sign in</p><p>{!session ? "visitor" : "member"}</p>
    )}, .{});
    defer destroy(program);

    const index = program.find("content/login.dynamic.publr").?;
    var target: ?[]const u8 = null;
    const signed_in: TestContext = .{
        .arena = arena,
        .live = true,
        .email = "ada@example.com",
        .redirected = &target,
    };
    const visitor: TestContext = .{ .arena = arena, .live = true, .redirected = &target };

    try testing.expect(program.templates[index].dynamic);
    try testing.expectError(error.Redirect, render_test(arena, program, index, &signed_in));
    try testing.expectEqualStrings("/spaces/mine", target.?);
    const page = try render_test(arena, program, index, &visitor);
    try testing.expect(contains(page, "sign in"));
    try testing.expect(contains(page, "<p>visitor</p>"));
}

test "call: a page runs an operation when it renders, after its redirects" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{source("content/welcome.dynamic.publr",
        \\---
        \\const session = Publr.request.session;
        \\if (!session) {
        \\  Publr.request.redirect('/login');
        \\} else {
        \\  Publr.request.call('app.cloud.welcome');
        \\}
        \\Publr.request.call('stats.view');
        \\---
        \\<p>welcome</p>
    )}, .{});
    defer destroy(program);

    const index = program.find("content/welcome.dynamic.publr").?;
    var calls: std.ArrayList([]const u8) = .empty;
    var target: ?[]const u8 = null;
    const member: TestContext = .{
        .arena = arena,
        .live = true,
        .email = "ada@example.com",
        .calls = &calls,
        .redirected = &target,
    };
    const visitor: TestContext = .{
        .arena = arena,
        .live = true,
        .calls = &calls,
        .redirected = &target,
    };

    try testing.expect(contains(try render_test(arena, program, index, &member), "welcome"));
    try testing.expectEqual(@as(usize, 2), calls.items.len);
    try testing.expectEqualStrings("app.cloud.welcome", calls.items[0]);
    try testing.expectEqualStrings("stats.view", calls.items[1]);

    // Redirected before the calls: nothing runs for a visitor sent elsewhere.
    try testing.expectError(error.Redirect, render_test(arena, program, index, &visitor));
    try testing.expectEqual(@as(usize, 2), calls.items.len);
}

test "conditions: `!`, `&&` and `||` read truthiness and give true or false" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{source("content/who.dynamic.publr",
        \\---
        \\const session = Publr.request.session;
        \\const agent = Publr.request.header('user-agent');
        \\---
        \\<p>[{session && agent ? "both" : "not both"}|{!session || !agent ? "gap" : "none"}]</p>
    )}, .{});
    defer destroy(program);

    const index = program.find("content/who.dynamic.publr").?;
    const full: TestContext = .{
        .arena = arena,
        .live = true,
        .email = "a@b.c",
        .user_agent = "x",
    };
    const half: TestContext = .{ .arena = arena, .live = true, .user_agent = "x" };

    try testing.expect(contains(try render_test(arena, program, index, &full), "[both|none]"));
    try testing.expect(contains(try render_test(arena, program, index, &half), "[not both|gap]"));
}

test "userField: the signed-in user's custom field as text, null when not there" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{source("content/me.dynamic.publr",
        \\---
        \\const welcomed = Publr.request.userField('cloud.welcomed');
        \\const home = Publr.request.userField('cloud.default_space');
        \\---
        \\<p>[{welcomed ?? "never"}|{home ?? "none"}]</p>
    )}, .{});
    defer destroy(program);

    const index = program.find("content/me.dynamic.publr").?;
    const member: TestContext = .{
        .arena = arena,
        .live = true,
        .user_fields = &.{.{ "cloud.welcomed", "true" }},
    };
    const nobody: TestContext = .{ .arena = arena, .live = true };

    try testing.expect(program.templates[index].dynamic);
    try testing.expect(contains(try render_test(arena, program, index, &member), "[true|none]"));
    try testing.expect(contains(try render_test(arena, program, index, &nobody), "[never|none]"));
}

const card_component = source("components/card.publr", fenced(
    "const item = props.entry.item;",
    "<li>{item.title}{props.note ?? \"\"}</li>",
));

test "unsupported constructs fail naming them" {
    for (refusals) |case| {
        const message = try refuse(case.sources, .{});
        defer testing.allocator.free(message);

        try testing.expectEqualStrings(case.message, message);
    }
}

test "the limits refuse an app that is too big, naming what" {
    var diagnostic: Diagnostic = .{ .arena = testing.allocator };
    const long = try testing.allocator.alloc(u8, source_bytes_max + 1);
    defer testing.allocator.free(long);
    @memset(long, 'x');

    const long_sources = [_]Source{source("content/index.publr", long)};
    const too_long = load(testing.allocator, &long_sources, .{}, &diagnostic);
    try testing.expectError(error.SourceTooLong, too_long);
    const named = "content/index.publr is longer than a template may be";
    try testing.expectEqualStrings(named, diagnostic.message);
    testing.allocator.free(diagnostic.message);

    const many = [_]Source{index_page} ** (templates_max + 1);
    const too_many = load(testing.allocator, &many, .{}, &diagnostic);
    try testing.expectError(error.TooManyTemplates, too_many);

    const layout_only = [_]Source{source("layouts/base.publr", "")};
    const none = load(testing.allocator, &layout_only, .{}, &diagnostic);
    try testing.expectError(error.NoPages, none);

    // One element more than the limit allows.
    const deep = "<div>" ** (nesting_max + 1) ++ "</div>" ** (nesting_max + 1);
    const message = try refuse(&.{source("content/index.publr", deep)}, .{});
    defer testing.allocator.free(message);
    const nested = "content/index.publr: markup nests deeper than 64 levels";
    try testing.expectEqualStrings(nested, message);
}

test "`.dynamic` on a component reading only the store: a credentialed island, never kept" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("components/fresh.dynamic.publr", fenced(posts_query, "<b>{posts.length}</b>")),
        source("content/uses.publr", fenced(
            "import Fresh from '../components/fresh.dynamic.publr';",
            "<head></head><Fresh dynamic eager />",
        )),
    }, .{});
    defer destroy(program);

    const fresh = program.templates[program.find("components/fresh.dynamic.publr").?];
    try testing.expect(fresh.dynamic);
    try testing.expect(!fresh.reads_request);
    try testing.expect(program.islands[0].dynamic);
    try testing.expectEqual(@as(u32, 0), program.islands[0].max_age);
    const page = try render_test(arena, program, program.routes[0].template, &.{ .arena = arena });
    const placeholder = "<publr-island src=\"/_islands/fresh\" credentials></publr-island>";
    try testing.expect(contains(page, placeholder));
}

test "dynamic-if: a dynamic island the browser fetches only when its condition holds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("components/fresh.dynamic.publr", fenced(posts_query, "<b>{posts.length}</b>")),
        source("content/uses.publr", fenced(
            "import Fresh from '../components/fresh.dynamic.publr';",
            "<head></head><Fresh dynamic-if=\"signedIn\" eager />",
        )),
    }, .{});
    defer destroy(program);

    try testing.expect(program.islands[0].dynamic);

    const page = try render_test(arena, program, program.routes[0].template, &.{ .arena = arena });
    const placeholder = "<publr-island src=\"/_islands/fresh\" credentials if=\"signedIn\">" ++
        "</publr-island>";
    try testing.expect(contains(page, placeholder));
    // Eager or not, never preloaded: a preload would fetch it whatever the condition says.
    try testing.expect(!contains(page, "rel=\"preload\""));
}

test "minify: markup collapses, whitespace that is content does not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("content/index.publr",
            \\<html>
            \\  <body>
            \\    <p class="lead">
            \\      Some words
            \\    </p>
            \\    <a href="/one">one</a> <a href="/two">two</a>
            \\    <pre>  keep
            \\  this  </pre>
            \\  </body>
            \\</html>
        ),
    }, .{ .minify = true });
    defer destroy(program);

    const page = try render_test(arena, program, 0, &.{ .arena = arena });
    const expected = "<html> <body> <p class=\"lead\"> Some words </p> <a href=\"/one\">one</a> " ++
        "<a href=\"/two\">two</a> <pre>  keep\n  this  </pre> </body> </html>";
    try testing.expectEqualStrings(expected, page);
}

test "dynamic site: every template is live and `island` embeds, plain server rendering" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("components/greeting.dynamic.publr", fenced(
            "const session = Publr.request.session;",
            "{session.email ?? \"nobody\"}",
        )),
        source("components/latest.publr", fenced(posts_query, "<b>{posts.length}</b><slot />")),
        source("content/index.publr",
            \\---
            \\import Greeting from '../components/greeting.dynamic.publr';
            \\import Latest from '../components/latest.publr';
            \\---
            \\<Greeting dynamic>…</Greeting><Latest island>more</Latest>
        ),
    }, .{ .dynamic = true });
    defer destroy(program);

    try testing.expect(program.routes[0].live);
    try testing.expectEqual(@as(usize, 0), program.islands.len);
    const live_ctx: TestContext = .{ .arena = arena, .live = true };
    const page = try render_test(arena, program, program.routes[0].template, &live_ctx);
    try testing.expectEqualStrings("nobody<b>2</b>more", page);
}

test "overrides: an added page becomes a route, an added component an importable name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const program = try load_test(&.{
        source("content/index.publr", fenced(
            "import Note from '../components/note.publr';",
            "<Note who=\"you\" />",
        )),
        .{ .rel = "content/about.publr", .source = "<p>added</p>", .origin = .added },
        .{
            .rel = "components/note.publr",
            .source = "<i>hi {props.who ?? \"there\"}</i>",
            .origin = .override,
        },
    }, .{});
    defer destroy(program);

    try testing.expectEqual(@as(usize, 2), program.routes.len);
    try testing.expectEqualStrings("/about", program.routes[1].pattern);
    const added = program.templates[program.routes[1].template].origin;
    try testing.expectEqual(Template.Origin.added, added);
    const home = try render_test(arena, program, program.routes[0].template, &.{ .arena = arena });
    try testing.expectEqualStrings("<i>hi you</i>", home);
}

test "invalid app paths and error-only apps fail loading gracefully" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{ .arena = arena_state.allocator() };

    for ([_][]const u8{
        "",
        "content/.publr",
        "content/../index.publr",
        "content//index.publr",
        "content/index",
        "content/" ++ "x" ** 1024 ++ ".publr",
    }) |rel| {
        const sources = [_]Source{.{ .rel = rel, .source = "<p>Hi</p>" }};
        try testing.expectError(
            error.Unsupported,
            load(
                testing.allocator,
                &sources,
                .{},
                &diagnostic,
            ),
        );
    }

    const only_error = [_]Source{.{ .rel = "content/404.publr", .source = "<p>Missing</p>" }};
    try testing.expectError(error.NoPages, load(testing.allocator, &only_error, .{}, &diagnostic));
}

test "deep expressions and empty request names fail at app compilation" {
    for ([_][]const u8{
        "<p>{" ++ "(" ** 100 ++ "'text'" ++ ")" ** 100 ++ "}</p>",
        "---\nconst header_value = Publr.request.header('');\n---\n<p>Hi</p>",
        "---\nconst cookie_value = Publr.request.cookie('');\n---\n<p>Hi</p>",
    }) |template_text| {
        const message = try refuse(
            &.{
                .{
                    .rel = "content/index.dynamic.publr",
                    .source = template_text,
                },
            },
            .{},
        );
        defer testing.allocator.free(message);
        try testing.expect(message.len > 0);
    }
}

fn check_load_allocation_failure(gpa: std.mem.Allocator) !void {
    std.debug.assert(templates_max > 0);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{ .arena = arena_state.allocator() };
    const loaded = try load(
        gpa,
        &.{.{ .rel = "content/index.publr", .source = "<p>Hi</p>" }},
        .{},
        &diagnostic,
    );
    defer gpa.destroy(loaded);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 1), loaded.routes.len);
}

test "app loading releases allocations on every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, check_load_allocation_failure, .{});
}
