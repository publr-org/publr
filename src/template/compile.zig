//! The reader of a `.publr` template: JS frontmatter over an HTML+JSX body, checked
//! with types and turned into `ast.zig`. Anything outside the subset fails naming the
//! template and the construct.

const std = @import("std");
const ast = @import("ast.zig");
const frontmatter = @import("frontmatter.zig");
const markup = @import("markup.zig");
const expression = @import("expression.zig");

const Type = ast.Type;
const Expr = ast.Expr;
const Node = ast.Node;
const Template = ast.Template;

pub const Error = error{Unsupported} || std.mem.Allocator.Error || std.Io.Writer.Error;

pub const split_template = expression.split_template;
pub const is_identifier = expression.is_identifier;

/// How deep markup, `{}` constructs and component children may nest.
pub const nesting_max: u32 = 64;
pub const islands_max: u32 = 256;
pub const props_max: u32 = 32;
pub const locals_max: u32 = 256;

/// A PJSX component the app may call: its name and which of its props are strings a
/// call site may fill (a trailing default lets a call site leave one out, or hand it
/// an optional).
pub const PjsxComponent = struct {
    name: []const u8,
    props: []const PjsxProp,
    /// Whether `children` is one of its props.
    takes_children: bool,
};

pub const PjsxProp = struct { name: []const u8, has_default: bool };

/// One `<X ... island />` call site, by fragment key: the component and the literal
/// props it is rendered with. Two call sites with the same key share one fragment.
pub const IslandUse = struct {
    key: []const u8,
    template: u32,
    props: []const ast.PropArg,
    dynamic: bool,
    /// How long a consumer may reuse the fragment before fetching it again; 0 is
    /// "revalidate every time".
    max_age: u32,
};

/// The default `cache` of a static island, in seconds.
pub const static_island_max_age: u32 = 60;

/// A named run of bytes: a template's text, a generated asset.
pub const File = struct { path: []const u8, data: []const u8 };

/// The compiled stylesheet's name under `/_app/`, beside the generated assets.
pub const stylesheet = "app.css";

pub const Options = struct {
    /// The whole site renders per request: every template dynamic, nothing built,
    /// `island` ignored.
    dynamic: bool = false,
    /// Markup collapsed as it is read: every run of whitespace to one space.
    minify: bool = false,
    pjsx: []const PjsxComponent = &.{},
    /// What Publr generates for the app, the only files an `/_app/...` URL may name.
    assets: []const File = &.{},
    /// The app's folder in the apps folder: an import that leads back into it is the app's.
    folder: []const u8 = "",
};

/// What `Compiler.run` works on and adds to: the app's templates and the islands its
/// call sites have declared so far.
pub const Context = struct {
    arena: std.mem.Allocator,
    templates: []Template,
    islands: std.ArrayList(IslandUse) = .empty,
    options: Options,
    /// The message of the last failure, for the caller to report.
    failure: []const u8 = "",
    nesting_depth: u32 = 0,

    /// Compiles template `index` once; a caller that imports it gets the memo.
    pub fn compile(context: *Context, index: u32) Error!void {
        std.debug.assert(index < context.templates.len);
        std.debug.assert(context.islands.items.len <= islands_max);

        if (context.templates[index].compiled) {
            return;
        }

        if (context.nesting_depth == nesting_max) {
            context.failure = try context.named_failure(index, "component imports nest too deeply");
            return error.Unsupported;
        }

        context.nesting_depth += 1;
        defer context.nesting_depth -= 1;
        var compiler: Compiler = .init(context, index);
        const original = context.templates[index];
        compiler.run() catch |native_error| {
            if (native_error != error.Unsupported or context.failure.len > 0) {
                return native_error;
            }

            if (!compiler.needs_javascript) {
                context.failure = try context.named_failure(index, compiler.failure);
                return native_error;
            }

            context.templates[index] = original;
            compiler = .init(context, index);
            compiler.javascript = true;
            compiler.run() catch |err| {
                if (err == error.Unsupported and context.failure.len == 0) {
                    context.failure = try context.named_failure(index, compiler.failure);
                }

                return err;
            };
        };
    }

    /// A message that already names its template is kept as is.
    fn named_failure(context: *Context, index: u32, message: []const u8) Error![]const u8 {
        std.debug.assert(index < context.templates.len);

        const rel = context.templates[index].rel;

        if (std.mem.indexOf(u8, message, rel) != null) {
            return message;
        }

        return std.fmt.allocPrint(context.arena, "{s}: {s}", .{ rel, message });
    }

    pub fn forced_dynamic(context: *const Context, rel: []const u8) bool {
        std.debug.assert(rel.len > 0);

        return context.options.dynamic or named_dynamic(rel);
    }
};

// ---- names and paths ---------------------------------------------------------------

/// Whether this file's name declares it dynamic.
pub fn named_dynamic(rel: []const u8) bool {
    return std.mem.endsWith(u8, rel, ".dynamic.publr");
}

fn basename_of(rel: []const u8) []const u8 {
    std.debug.assert(rel.len > 0);

    const slash = std.mem.lastIndexOfScalar(u8, rel, '/') orelse return rel;

    std.debug.assert(slash < rel.len);

    return rel[slash + 1 ..];
}

/// "content/visit.publr" becomes "visit.dynamic.publr": the name a dynamic page must have.
pub fn dynamic_name(arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
    std.debug.assert(std.mem.endsWith(u8, rel, ".publr"));

    const basename = basename_of(rel);
    const stem = basename[0 .. basename.len - ".publr".len];

    std.debug.assert(stem.len > 0);

    return std.fmt.allocPrint(arena, "{s}.dynamic.publr", .{stem});
}

/// "components/pure.dynamic.publr" becomes "pure.publr": the name it should have.
pub fn static_name(arena: std.mem.Allocator, rel: []const u8) ![]const u8 {
    std.debug.assert(named_dynamic(rel));

    const basename = basename_of(rel);
    const stem = basename[0 .. basename.len - ".dynamic.publr".len];

    std.debug.assert(stem.len > 0);

    return std.fmt.allocPrint(arena, "{s}.publr", .{stem});
}

/// The path without `.publr`, and without a `.dynamic` marker.
pub fn stem_of(rel: []const u8) []const u8 {
    std.debug.assert(std.mem.endsWith(u8, rel, ".publr"));

    const without = rel[0 .. rel.len - ".publr".len];

    if (std.mem.endsWith(u8, without, ".dynamic")) {
        return without[0 .. without.len - ".dynamic".len];
    }

    return without;
}

/// "components/latest-posts.publr" + `limit=3` becomes "latest-posts-9e1b4c2a": the
/// component's stem (nested folders kept), then a hash of the sorted `name=value`
/// props when there are any. Two call sites agreeing on props share the key.
pub fn island_key(
    arena: std.mem.Allocator,
    rel: []const u8,
    literals: []const []const u8,
) ![]const u8 {
    std.debug.assert(std.mem.indexOfScalar(u8, rel, '/') != null);
    std.debug.assert(literals.len <= props_max);

    const top_end = std.mem.indexOfScalar(u8, rel, '/').?;
    const stem = stem_of(rel)[top_end + 1 ..];

    if (literals.len == 0) {
        return stem;
    }

    const sorted = try arena.dupe([]const u8, literals);
    std.mem.sort([]const u8, sorted, {}, string_less_than);
    var hash = std.hash.Fnv1a_32.init();

    for (sorted) |pair| {
        hash.update(pair);
        hash.update("\n");
    }

    return std.fmt.allocPrint(arena, "{s}-{x:0>8}", .{ stem, hash.final() });
}

pub fn string_less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

/// `./components/Disclosure.ptsx` becomes `Disclosure`.
pub fn file_stem(path: []const u8) []const u8 {
    std.debug.assert(path.len > 0);

    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const start = if (slash) |index| index + 1 else 0;
    const dot = std.mem.lastIndexOfScalar(u8, path[start..], '.') orelse path.len - start;

    std.debug.assert(start + dot <= path.len);

    return path[start .. start + dot];
}

// ---- the compiler ------------------------------------------------------------------

pub const Local = struct {
    name: []const u8,
    type: Type,
};

/// A local name bound by an `import` in the frontmatter: a `.publr` template by index,
/// or a PJSX component.
pub const Import = struct { local: []const u8, index: u32 = 0, pjsx: ?u32 = null };

/// One template's read, statement by statement, into node lists.
pub const Compiler = struct {
    context: *Context,
    arena: std.mem.Allocator,
    index: u32,
    template: *Template,
    /// The list nodes are appended to: the body at the top, a children (or branch, or
    /// loop) list inside one.
    out: *std.ArrayList(Node),
    /// Static markup accumulated since the last node; flushed as one text node.
    pending: std.ArrayList(u8),
    literal_depth: u32 = 0,
    pending_space: bool = false,
    /// How deep the markup being read nests, against `nesting_max`.
    depth: u32 = 0,
    locals: std.ArrayList(Local),
    imports: std.ArrayList(Import),
    prop_names: std.ArrayList([]const u8),
    entry_props: std.ArrayList([]const u8),
    static_island_keys: std.ArrayList([]const u8),
    static_idle_keys: std.ArrayList([]const u8),
    dynamic_eager_keys: std.ArrayList([]const u8),
    dynamic_idle_keys: std.ArrayList([]const u8),
    classes: std.ArrayList([]const u8),
    decls: std.ArrayList(ast.Decl),
    failure: []const u8 = "",
    source: []const u8 = "",
    position: u32 = 0,
    javascript: bool = false,
    needs_javascript: bool = false,
    js_frontmatter: []const u8 = "",
    js_expressions: std.ArrayList([]const u8) = .empty,
    js_embeds: std.ArrayList(u32) = .empty,
    js_imports: std.ArrayList([]const u8) = .empty,
    js_modules: std.ArrayList(u32) = .empty,

    pub fn init(context: *Context, index: u32) Compiler {
        std.debug.assert(index < context.templates.len);
        std.debug.assert(!context.templates[index].compiled);

        return .{
            .context = context,
            .arena = context.arena,
            .index = index,
            .template = &context.templates[index],
            .out = undefined,
            .pending = .empty,
            .locals = .empty,
            .imports = .empty,
            .prop_names = .empty,
            .entry_props = .empty,
            .static_island_keys = .empty,
            .static_idle_keys = .empty,
            .dynamic_eager_keys = .empty,
            .dynamic_idle_keys = .empty,
            .classes = .empty,
            .decls = .empty,
        };
    }

    pub fn fail(compiler: *Compiler, comptime format: []const u8, args: anytype) Error {
        std.debug.assert(format.len > 0);

        compiler.failure = std.fmt.allocPrint(compiler.arena, format, args) catch
            "out of memory while reporting";

        std.debug.assert(compiler.failure.len > 0);

        return error.Unsupported;
    }

    /// A language construct outside the native optimizer, rather than a policy error.
    pub fn script(compiler: *Compiler, comptime format: []const u8, args: anytype) Error {
        compiler.needs_javascript = true;
        return compiler.fail(format, args);
    }

    /// A short, single-line excerpt of source for a message.
    pub fn excerpt(compiler: *Compiler, text: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const cut = @min(trimmed.len, 60);
        const first_line = std.mem.indexOfScalar(u8, trimmed[0..cut], '\n') orelse cut;

        std.debug.assert(first_line <= cut);
        std.debug.assert(cut <= 60);

        return compiler.arena.dupe(u8, trimmed[0..first_line]) catch "";
    }

    pub fn run(compiler: *Compiler) Error!void {
        const template = compiler.template;

        std.debug.assert(!template.compiled);

        if (template.compiling) {
            return compiler.fail("imports itself, directly or through another template", .{});
        }

        template.compiling = true;

        if (template.kind == .module) {
            return @import("javascript/compile.zig").module(compiler);
        }

        if (compiler.context.forced_dynamic(template.rel)) {
            template.dynamic = true;
        }

        var body: std.ArrayList(Node) = .empty;
        compiler.out = &body;

        const parts = split_template(template.source);

        if (compiler.javascript) {
            try @import("javascript/compile.zig").frontmatter(compiler, parts.frontmatter);
        } else {
            try frontmatter.read(compiler, parts.frontmatter);
        }

        compiler.source = parts.body;
        compiler.position = 0;
        try markup.parse(compiler, null);
        try compiler.flush();

        if (compiler.javascript) {
            try @import("javascript/compile.zig").finish(compiler);
        }

        try compiler.check_whole();

        template.decls = compiler.decls.items;
        template.body = body.items;
        template.props = compiler.prop_names.items;
        template.entry_props = compiler.entry_props.items;
        template.static_island_keys = compiler.static_island_keys.items;
        template.static_idle_keys = compiler.static_idle_keys.items;
        template.dynamic_eager_keys = compiler.dynamic_eager_keys.items;
        template.dynamic_idle_keys = compiler.dynamic_idle_keys.items;
        template.classes = compiler.classes.items;
        template.compiling = false;
        template.compiled = true;

        std.debug.assert(compiler.depth == 0);
    }

    /// What can only be judged once the whole template is read.
    fn check_whole(compiler: *Compiler) Error!void {
        const template = compiler.template;

        std.debug.assert(template.compiling);

        const headless = template.kind == .page and template.page_islands() and !template.has_head;

        if (headless) {
            return compiler.fail(
                "Page {s} has islands but writes no <head> to carry the island loader",
                .{template.rel},
            );
        }

        // `.dynamic` says when something renders, and that is only a question when two
        // renders could differ: a template that reads nothing is a pure function of its
        // props, so rendering it per request would serve identical bytes under
        // `no-store` forever.

        if (named_dynamic(template.rel) and !template.reads_data) {
            return compiler.fail(
                "{s} reads nothing, so every render is the same bytes — `.dynamic` would " ++
                    "make it uncacheable for no gain. Rename it to {s}",
                .{ template.rel, try static_name(compiler.arena, template.rel) },
            );
        }
    }

    // -- nodes --

    pub fn push(compiler: *Compiler, node: Node) Error!void {
        try compiler.flush();
        try compiler.out.append(compiler.arena, node);

        std.debug.assert(compiler.pending.items.len == 0);
    }

    pub fn static(compiler: *Compiler, text: []const u8) Error!void {
        try compiler.pending.appendSlice(compiler.arena, text);
    }

    pub fn flush(compiler: *Compiler) Error!void {
        if (compiler.pending.items.len == 0) {
            return;
        }

        const collapse = compiler.context.options.minify and compiler.literal_depth == 0;
        const text = if (collapse)
            try compiler.collapsed(compiler.pending.items)
        else
            try compiler.arena.dupe(u8, compiler.pending.items);

        compiler.pending.clearRetainingCapacity();

        std.debug.assert(compiler.pending.items.len == 0);

        if (text.len == 0) {
            return;
        }

        try compiler.out.append(compiler.arena, .{ .text = text });
    }

    /// Markup with every run of whitespace collapsed to a single space, never dropped:
    /// between two inline elements that space is a word gap. `pending_space` carries the
    /// run across flushes, so the whitespace on either side of an interpolated `{value}`
    /// collapses to one space.
    fn collapsed(compiler: *Compiler, text: []const u8) Error![]const u8 {
        std.debug.assert(compiler.context.options.minify);
        std.debug.assert(compiler.literal_depth == 0);

        var out: std.Io.Writer.Allocating = try .initCapacity(compiler.arena, text.len);

        for (text) |byte| {
            const space = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';

            if (space) {
                if (!compiler.pending_space) {
                    try out.writer.writeByte(' ');
                }

                compiler.pending_space = true;
            } else {
                try out.writer.writeByte(byte);
                compiler.pending_space = false;
            }
        }

        return out.written();
    }

    /// Enters a nested markup level, refusing past `nesting_max`.
    pub fn descend(compiler: *Compiler) Error!void {
        std.debug.assert(compiler.depth <= nesting_max);

        if (compiler.depth == nesting_max or compiler.context.nesting_depth == nesting_max) {
            return compiler.fail("markup nests deeper than {d} levels", .{nesting_max});
        }

        compiler.depth += 1;
        compiler.context.nesting_depth += 1;
    }

    pub fn ascend(compiler: *Compiler) void {
        std.debug.assert(compiler.depth > 0);

        compiler.depth -= 1;
        compiler.context.nesting_depth -= 1;
    }

    pub fn add_local(compiler: *Compiler, name: []const u8, kind: Type) Error!void {
        std.debug.assert(name.len > 0);

        if (compiler.locals.items.len == locals_max) {
            return compiler.fail("more than {d} names declared", .{locals_max});
        }

        for (compiler.locals.items) |local| {
            if (std.mem.eql(u8, local.name, name)) {
                return compiler.fail("`{s}` is declared twice", .{name});
            }
        }

        try compiler.locals.append(compiler.arena, .{ .name = name, .type = kind });
    }

    pub fn find_local(compiler: *Compiler, name: []const u8) ?*Local {
        std.debug.assert(compiler.locals.items.len <= locals_max);

        var index = compiler.locals.items.len;

        while (index > 0) {
            index -= 1;

            if (std.mem.eql(u8, compiler.locals.items[index].name, name)) {
                return &compiler.locals.items[index];
            }
        }

        return null;
    }

    pub fn note_static_island(compiler: *Compiler, key: []const u8, idle: bool) Error!void {
        std.debug.assert(key.len > 0);

        const set = if (idle) &compiler.static_idle_keys else &compiler.static_island_keys;

        try note(compiler.arena, set, key);
    }

    pub fn box(compiler: *Compiler, value: Expr) Error!*const Expr {
        const boxed = try compiler.arena.create(Expr);
        boxed.* = value;

        return boxed;
    }
};

/// Records a key on a set, once, keeping it sorted: the loader sorts the keys it
/// batches, so the URL a page preloads has to be sorted the same way.
pub fn note(arena: std.mem.Allocator, set: *std.ArrayList([]const u8), key: []const u8) Error!void {
    std.debug.assert(key.len > 0);
    std.debug.assert(set.items.len <= islands_max);

    var at: u32 = 0;

    while (at < set.items.len) : (at += 1) {
        const order = std.mem.order(u8, set.items[at], key);

        if (order == .eq) {
            return;
        }

        if (order == .gt) {
            break;
        }
    }

    try set.insert(arena, at, key);
}

test "island keys, dynamic names and import paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const expect = std.testing.expectEqualStrings;

    try expect("ticker", try island_key(arena, "components/ticker.dynamic.publr", &.{}));
    try expect("latest", try island_key(arena, "components/latest.publr", &.{}));
    try expect(
        try island_key(arena, "components/latest.publr", &.{ "a=1", "b=2" }),
        try island_key(arena, "components/latest.publr", &.{ "b=2", "a=1" }),
    );
    const one = try island_key(arena, "components/latest.publr", &.{"a=1"});
    const two = try island_key(arena, "components/latest.publr", &.{"a=2"});
    try std.testing.expect(!std.mem.eql(u8, one, two));

    try std.testing.expect(named_dynamic("content/fresh.dynamic.publr"));
    try std.testing.expect(!named_dynamic("content/fresh.publr"));
    try expect("fresh.dynamic.publr", try dynamic_name(arena, "content/fresh.publr"));
    try expect("pure.publr", try static_name(arena, "components/pure.dynamic.publr"));
    try expect("content/posts/index", stem_of("content/posts/index.dynamic.publr"));
    try expect("Disclosure", file_stem("../interactive/Disclosure.ptsx"));
}

test "note keeps a sorted set of keys, once each" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var set: std.ArrayList([]const u8) = .empty;
    try note(arena, &set, "middle");
    try note(arena, &set, "alpha");
    try note(arena, &set, "zulu");
    try note(arena, &set, "middle");
    try std.testing.expectEqual(@as(usize, 3), set.items.len);
    try std.testing.expectEqualStrings("alpha", set.items[0]);
    try std.testing.expectEqualStrings("middle", set.items[1]);
    try std.testing.expectEqualStrings("zulu", set.items[2]);
}
