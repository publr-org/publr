//! The site as the server holds it: the embedded theme loaded by the engine, its stylesheet
//! compiled by the JIT, generated client code under one fingerprint, and the static
//! output directory. Public files stay on disk outside this generated-artifact state.

const std = @import("std");
const report = @import("../../lib/report.zig");
const jit = @import("publr_jit");
const theme_options = @import("theme_options");
const theme_templates = @import("theme_templates");
const theme_assets = @import("theme_assets");
const theme_interactive = @import("theme_interactive");
const runtime = @import("runtime");
const engine = @import("../../theme.zig");
const deps = @import("../../lib/deps.zig");

pub const name: []const u8 = theme_options.theme_name;
pub const minify: bool = theme_options.minify;
pub const version_len: u32 = 16;
pub const assets_max: u32 = 256;
pub const public_dir = "themes/" ++ name ++ "/public";
pub const output_dir_default = "output";
pub const base_url_default = "http://127.0.0.1:8080";

const theme_tokens: jit.Theme = @import("theme_tokens");
const merged_tokens: jit.Theme = jit.extendTheme(jit.default_theme, theme_tokens);
const preflight_css = @embedFile("theme_preflight_css");
const style_css = @embedFile("theme_style_css");
const interactive_classes = @embedFile("theme_interactive_classes");

pub const Asset = struct { path: []const u8, data: []const u8 };

pub const Options = struct {
    output_dir: []const u8 = output_dir_default,
    base_url: []const u8 = base_url_default,
    /// Nothing cached anywhere, every placed island tinted, nothing served from a build.
    dev: bool = false,
    /// How long a CDN in front may keep a built page or static island
    /// (`CDN-Cache-Control`), when it purges them as they change; 0 for no CDN, so they
    /// are kept no longer than a browser keeps them.
    edge_max_age: u32 = 0,
    /// `[DEPS]` lines on stderr for every rebuild.
    log: bool = false,
    /// Caller-owned storage for the cause, including across failed startup cleanup.
    diagnostic: ?*report.Reason = null,
};

pub fn valid_options(options: Options) bool {
    std.debug.assert(output_dir_default.len > 0);

    if (options.output_dir.len == 0) {
        return false;
    }

    if (std.mem.indexOfAny(u8, options.base_url, " \t\r\n") != null) {
        return false;
    }

    const uri = std.Uri.parse(options.base_url) catch return false;

    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
        return false;
    }

    const host = uri.host orelse return false;
    return !host.isEmpty();
}

pub const Public = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    index: *deps.Index,
    theme: *engine.Theme,
    css: []const u8,
    /// Changes when generated client code or the compiled stylesheet changes.
    version: [version_len]u8,
    /// The embedded assets, relative imports between the JS files fingerprinted.
    assets: []const Asset,
    /// What `stores.js` imports, transitively: the page preloads them beside it.
    stores_imports: []const []const u8,
    output: ?std.Io.Dir = null,
    options: Options,
    /// What a build depends on besides the records: the templates, `version` (the
    /// stylesheet and the assets) and the site's address. A folder built under another
    /// stamp is another site, rebuilt whole.
    build_stamp: [version_len]u8,
    /// `Publr.build.now()`: when the site was last built.
    built_at: i64,
    /// A failed static build must not expose partial output or attempt live rendering.
    build_ready: bool = true,
    retry_revision: u64 = 0,

    pub const Error = engine.LoadError || jit.CompileError || std.mem.Allocator.Error ||
        error{InvalidOptions};

    /// Loads the embedded theme (a theme that does not load is a startup failure naming
    /// the template) and compiles its stylesheet.
    pub fn init(
        public: *Public,
        gpa: std.mem.Allocator,
        io: std.Io,
        index: *deps.Index,
        options: Options,
        now_ms: i64,
    ) Error!void {
        if (options.diagnostic) |reason| {
            reason.len = 0;
        }

        if (!valid_options(options)) {
            return error.InvalidOptions;
        }

        std.debug.assert(now_ms >= 0);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var diagnostic: engine.Diagnostic = .{ .arena = arena };

        public.gpa = gpa;
        public.io = io;
        public.index = index;
        public.options = options;
        public.built_at = now_ms;
        public.output = null;
        public.build_ready = true;
        public.retry_revision = 0;
        const loaded = engine.load(gpa, try sources(arena), engine_options, &diagnostic);

        public.theme = loaded catch |err| {
            if (options.diagnostic) |reason| {
                reason.set("[theme] {s}", .{diagnostic.message});
            }

            return err;
        };
        errdefer destroy(gpa, public.theme);

        public.css = try compile_css(gpa, public.theme);
        errdefer gpa.free(public.css);

        public.version = stamp(public.css);
        public.assets = try rewrite_assets(gpa, &public.version);
        errdefer free_assets(gpa, public.assets);

        public.stores_imports = try imports_of(gpa, public.assets, "stores.js");
        public.build_stamp = build_stamp(&public.version, options.base_url);

        std.debug.assert(public.theme.routes.len > 0);
    }

    pub fn deinit(public: *Public) void {
        std.debug.assert(public.theme.templates.len > 0);
        std.debug.assert(public.css.len > 0);

        if (public.output) |*dir| {
            dir.close(public.io);
        }

        public.gpa.free(public.stores_imports);
        free_assets(public.gpa, public.assets);
        public.gpa.free(public.css);
        destroy(public.gpa, public.theme);
        public.* = undefined;
    }

    /// Opens (creating) the output folder: the build writes there and `serve` reads.
    pub fn open_output(public: *Public) !void {
        std.debug.assert(public.options.output_dir.len > 0);
        std.debug.assert(public.output == null);

        const cwd = std.Io.Dir.cwd();

        public.output = try cwd.createDirPathOpen(public.io, public.options.output_dir, .{});
    }

    /// Opens the output folder only when a build already exists there.
    pub fn open_existing_output(public: *Public) void {
        std.debug.assert(public.options.output_dir.len > 0);
        std.debug.assert(public.output == null);

        const cwd = std.Io.Dir.cwd();

        public.output = cwd.openDir(public.io, public.options.output_dir, .{}) catch null;
    }

    pub fn asset(public: *const Public, path: []const u8) ?[]const u8 {
        std.debug.assert(path.len > 0);
        std.debug.assert(public.assets.len <= assets_max);

        for (public.assets) |file| {
            if (std.mem.eql(u8, file.path, path)) {
                return file.data;
            }
        }

        return null;
    }

    /// Whether `token` is this site's fingerprint: bytes under that URL can never change.
    pub fn fingerprinted(public: *const Public, token: ?[]const u8) bool {
        std.debug.assert(public.version.len == version_len);
        std.debug.assert(public.css.len > 0);

        const asked = token orelse return false;

        return std.mem.eql(u8, asked, &public.version);
    }
};

pub const engine_options: engine.Options = .{
    .minify = minify,
    .pjsx = pjsx_components,
};

/// Compiles the embedded theme and its stylesheet as `serve` would, with no database: the
/// build runs it (`publr check-theme`), so a template the engine refuses fails the build
/// rather than the first start. Null when it compiles; else why not, in `arena`.
pub fn check_theme(gpa: std.mem.Allocator, arena: std.mem.Allocator) !?[]const u8 {
    std.debug.assert(engine.templates_max > 0);

    var diagnostic: engine.Diagnostic = .{ .arena = arena };
    const theme = engine.load(gpa, try sources(arena), engine_options, &diagnostic) catch |err| {
        const message = if (diagnostic.message.len > 0) diagnostic.message else @errorName(err);

        return try std.fmt.allocPrint(arena, "{s}", .{message});
    };
    defer destroy(gpa, theme);

    const css = compile_css(gpa, theme) catch |err| {
        return try std.fmt.allocPrint(arena, "the stylesheet: {s}", .{@errorName(err)});
    };
    defer gpa.free(css);

    return null;
}

fn destroy(gpa: std.mem.Allocator, theme: *engine.Theme) void {
    std.debug.assert(theme.templates.len > 0);
    std.debug.assert(theme.options.pjsx.len == pjsx_components.len);

    theme.deinit();
    gpa.destroy(theme);
}

/// The embedded templates as the engine's sources.
fn sources(arena: std.mem.Allocator) ![]const engine.Source {
    std.debug.assert(engine.templates_max > 0);

    if (theme_templates.files.len == 0) {
        return error.NoPages;
    }

    if (theme_templates.files.len > engine.templates_max) {
        return error.TooManyTemplates;
    }

    const list = try arena.alloc(engine.Source, theme_templates.files.len);

    for (theme_templates.files, list) |file, *source| {
        source.* = .{ .rel = file.path, .source = file.data, .origin = .theme };
    }

    return list;
}

/// Preflight, the theme's own `style.css`, then the JIT over every class the templates and
/// the interactive components name. Owned by the caller.
pub fn compile_css(gpa: std.mem.Allocator, theme: *const engine.Theme) ![]const u8 {
    std.debug.assert(theme.templates.len > 0);
    std.debug.assert(preflight_css.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var classes: std.ArrayList([]const u8) = .empty;

    try classes.appendSlice(arena, theme.classes);

    var tokens = std.mem.tokenizeAny(u8, interactive_classes, " \t\r\n");

    while (tokens.next()) |class| {
        try classes.append(arena, class);
    }

    const utilities = try jit.compile(arena, merged_tokens, classes.items, .{ .minify = minify });
    const separator: []const u8 = if (minify) "" else "\n";
    const parts = [_][]const u8{ preflight_css, separator, style_css, separator, utilities };

    return std.mem.concat(gpa, u8, &parts);
}

/// Fingerprint generated code and CSS only. Public files never enter this hash.
fn stamp(css: []const u8) [version_len]u8 {
    std.debug.assert(css.len > 0);
    const embedded_hash = assets_hash();

    std.debug.assert(embedded_hash != 0);

    var hash = std.hash.Fnv1a_64.init();
    var out: [version_len]u8 = undefined;

    hash.update(std.mem.asBytes(&embedded_hash));
    hash.update(css);
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{hash.final()}) catch unreachable;

    return out;
}

/// Every template's path and text, the fingerprint, the base address and core's own source
/// (`engine_stamp`: a Publr that renders differently builds every page again), as one stamp.
fn build_stamp(version: *const [version_len]u8, base_url: []const u8) [version_len]u8 {
    std.debug.assert(base_url.len > 0);
    std.debug.assert(theme_templates.files.len > 0);

    var hash = std.hash.Fnv1a_64.init();
    var out: [version_len]u8 = undefined;

    for (theme_templates.files) |file| {
        hash.update(file.path);
        hash.update(file.data);
    }

    hash.update(version);
    hash.update(base_url);
    hash.update(theme_options.engine_stamp);
    _ = std.fmt.bufPrint(&out, "{x:0>16}", .{hash.final()}) catch unreachable;

    return out;
}

fn assets_hash() u64 {
    std.debug.assert(theme_assets.files.len > 0);
    std.debug.assert(theme_assets.files.len <= assets_max);

    var hash = std.hash.Fnv1a_64.init();

    for (theme_assets.files) |file| {
        hash.update(file.path);
        hash.update(file.data);
    }

    return hash.final();
}

/// The embedded assets under the fingerprint: every `"./x.js"` import in a JS file becomes
/// `"./x.js?v=<token>"`, so a module reached through another is as immutable as the one
/// the page linked. Everything else is embedded as it is.
fn rewrite_assets(gpa: std.mem.Allocator, version: *const [version_len]u8) ![]const Asset {
    std.debug.assert(theme_assets.files.len <= assets_max);
    std.debug.assert(version.len == version_len);

    const rewritten = try gpa.alloc(Asset, theme_assets.files.len);
    var done: u32 = 0;
    errdefer {
        for (rewritten[0..done]) |file| {
            gpa.free(file.data);
        }

        gpa.free(rewritten);
    }

    for (theme_assets.files, rewritten) |embedded, *out| {
        out.* = .{ .path = embedded.path, .data = try fingerprint_imports(gpa, embedded, version) };
        done += 1;
    }

    return rewritten;
}

fn fingerprint_imports(
    gpa: std.mem.Allocator,
    embedded: theme_assets.File,
    version: *const [version_len]u8,
) ![]const u8 {
    std.debug.assert(embedded.path.len > 0);
    std.debug.assert(version.len == version_len);

    if (!std.mem.endsWith(u8, embedded.path, ".js")) {
        return gpa.dupe(u8, embedded.data);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var data: []const u8 = embedded.data;

    for (theme_assets.files) |sibling| {
        if (!std.mem.endsWith(u8, sibling.path, ".js")) {
            continue;
        }

        for ([_]u8{ '"', '\'' }) |quote| {
            const bare = try std.fmt.allocPrint(arena, "{c}./{s}{c}", .{
                quote,
                sibling.path,
                quote,
            });
            const stamped = try std.fmt.allocPrint(arena, "{c}./{s}?v={s}{c}", .{
                quote,
                sibling.path,
                version,
                quote,
            });

            data = try std.mem.replaceOwned(u8, arena, data, bare, stamped);
        }
    }

    return gpa.dupe(u8, data);
}

fn free_assets(gpa: std.mem.Allocator, assets: []const Asset) void {
    std.debug.assert(assets.len <= assets_max);
    std.debug.assert(theme_assets.files.len <= assets_max);

    for (assets) |file| {
        gpa.free(file.data);
    }

    gpa.free(assets);
}

/// The JS files `root` imports, transitively, breadth first, each once, by path.
fn imports_of(gpa: std.mem.Allocator, assets: []const Asset, root: []const u8) ![]const []const u8 {
    std.debug.assert(root.len > 0);
    std.debug.assert(assets.len <= assets_max);

    var reached: [assets_max][]const u8 = undefined;
    var count: u32 = 0;
    var next: u32 = 0;

    reached[0] = root;
    count += 1;

    while (next < count) : (next += 1) {
        const data = find_asset(assets, reached[next]) orelse continue;

        for (assets) |candidate| {
            const already = contains(reached[0..count], candidate.path);
            const imported = std.mem.indexOf(u8, data, candidate.path) != null;

            if (std.mem.endsWith(u8, candidate.path, ".js") and imported and !already) {
                reached[count] = candidate.path;
                count += 1;
            }
        }
    }

    return gpa.dupe([]const u8, reached[1..count]);
}

fn find_asset(assets: []const Asset, path: []const u8) ?[]const u8 {
    std.debug.assert(path.len > 0);
    std.debug.assert(assets.len <= assets_max);

    for (assets) |file| {
        if (std.mem.eql(u8, file.path, path)) {
            return file.data;
        }
    }

    return null;
}

fn contains(list: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);
    std.debug.assert(list.len <= assets_max);

    for (list) |item| {
        if (std.mem.eql(u8, item, wanted)) {
            return true;
        }
    }

    return false;
}

/// The lowered components a template can place by name. The lowering also carries every
/// design-system part they import (a `Button` with its required children); a template
/// places only a component whose props all start from a default.
const placeable_decls: []const std.builtin.Type.Declaration = blk: {
    @setEvalBranchQuota(100_000);

    const decls = @typeInfo(theme_interactive).@"struct".decls;
    var kept: [decls.len]std.builtin.Type.Declaration = undefined;
    var count: u32 = 0;

    for (decls) |decl| {
        if (placeable(@field(theme_interactive, decl.name))) {
            kept[count] = decl;
            count += 1;
        }
    }

    const final = kept[0..count].*;

    break :blk &final;
};

fn placeable(comptime Component: type) bool {
    comptime std.debug.assert(@typeInfo(Component) == .@"struct");

    if (!@hasDecl(Component, "Props") or !@hasDecl(Component, "render")) {
        return false;
    }

    for (@typeInfo(Component.Props).@"struct".fields) |field| {
        if (field.default_value_ptr == null) {
            return false;
        }
    }

    return true;
}

/// The theme's interactive components as the engine sees them: names and string props
/// read off each lowered module's `Props` type. The PublrJS transport props (`publr_*`)
/// are the compiler's, not a theme's.
pub const pjsx_components: []const engine.PjsxComponent = blk: {
    @setEvalBranchQuota(100_000);

    const decls = placeable_decls;
    var components: [decls.len]engine.PjsxComponent = undefined;

    for (decls, 0..) |decl, index| {
        const Component = @field(theme_interactive, decl.name);
        const fields = @typeInfo(Component.Props).@"struct".fields;
        var props: [fields.len]engine.PjsxProp = undefined;
        var count: u32 = 0;
        var takes_children = false;

        for (fields) |field| {
            if (std.mem.eql(u8, field.name, "children")) {
                takes_children = true;
            } else if (is_string_prop(field)) {
                props[count] = .{
                    .name = field.name,
                    .has_default = field.default_value_ptr != null,
                };
                count += 1;
            }
        }

        const kept = props[0..count].*;

        components[index] = .{
            .name = decl.name,
            .props = &kept,
            .takes_children = takes_children,
        };
    }

    const final = components;

    break :blk &final;
};

/// The same components' render functions, by the same index, wrapped to take props by name.
pub const pjsx_renders: []const engine.PjsxRender = blk: {
    const decls = placeable_decls;
    var renders: [decls.len]engine.PjsxRender = undefined;

    for (decls, 0..) |decl, index| {
        renders[index] = &Thunk(@field(theme_interactive, decl.name)).render;
    }

    const final = renders;

    break :blk &final;
};

fn is_string_prop(comptime field: std.builtin.Type.StructField) bool {
    std.debug.assert(field.name.len > 0);

    if (std.mem.startsWith(u8, field.name, "publr_")) {
        return false;
    }

    return field.type == []const u8 or field.type == ?[]const u8;
}

/// A call site's values over the component's own defaults; a null leaves the default.
fn Thunk(comptime Component: type) type {
    return struct {
        fn render(
            writer: *std.Io.Writer,
            arena: std.mem.Allocator,
            props: []const engine.Prop,
            children: ?[]const u8,
        ) anyerror!void {
            std.debug.assert(props.len <= engine.props_max);
            std.debug.assert(@hasDecl(Component, "render"));

            var filled: Component.Props = .{};

            inline for (@typeInfo(Component.Props).@"struct".fields) |field| {
                if (comptime is_string_prop(field) and !std.mem.eql(u8, field.name, "children")) {
                    for (props) |prop| {
                        if (std.mem.eql(u8, prop.name, field.name)) {
                            if (prop.value) |value| {
                                @field(filled, field.name) = value;
                            }
                        }
                    }
                }
            }

            if (children) |text| {
                if (@hasField(Component.Props, "children")) {
                    filled.children = runtime.raw(text);
                }
            }

            try Component.render(writer, arena, filled);
        }
    };
}

test "the fingerprint follows the stylesheet" {
    const one = stamp("a{}");
    const two = stamp("b{}");
    try std.testing.expect(!std.mem.eql(u8, &one, &two));
    try std.testing.expectEqualStrings(&one, &stamp("a{}"));
}

test "the build stamp follows the fingerprint and the address" {
    const one = stamp("a{}");
    const two = stamp("b{}");
    const same = build_stamp(&one, "http://a");
    try std.testing.expectEqualStrings(&same, &build_stamp(&one, "http://a"));
    try std.testing.expect(!std.mem.eql(u8, &same, &build_stamp(&two, "http://a")));
    try std.testing.expect(!std.mem.eql(u8, &same, &build_stamp(&one, "http://b")));
}

test "relative imports between assets carry the fingerprint; other files are untouched" {
    const version: [version_len]u8 = "0123456789abcdef".*;
    const rewritten = try rewrite_assets(std.testing.allocator, &version);
    defer free_assets(std.testing.allocator, rewritten);

    for (rewritten) |file| {
        if (std.mem.eql(u8, file.path, "publr.js")) {
            const stamped = "./ref.js?v=0123456789abcdef";
            const bare = "\"./ref.js\"";
            try std.testing.expect(std.mem.indexOf(u8, file.data, stamped) != null);
            try std.testing.expect(std.mem.indexOf(u8, file.data, bare) == null);
        }
    }

    const imports = try imports_of(std.testing.allocator, rewritten, "stores.js");
    defer std.testing.allocator.free(imports);

    for (imports) |path| {
        try std.testing.expect(std.mem.endsWith(u8, path, ".js"));
    }
}

fn check_asset_allocation_failure(gpa: std.mem.Allocator) !void {
    const version: [version_len]u8 = "0123456789abcdef".*;
    const rewritten = try rewrite_assets(gpa, &version);
    defer free_assets(gpa, rewritten);
}

test "asset rewriting frees the full allocation after every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        check_asset_allocation_failure,
        .{},
    );
}

test "site options reject empty paths and malformed base addresses" {
    try std.testing.expect(!valid_options(.{ .output_dir = "" }));

    for ([_][]const u8{
        "",
        "/",
        "///",
        "https://",
        "relative",
        "ftp://example.com",
        "https://example.com\n",
    }) |url| {
        try std.testing.expect(!valid_options(.{ .base_url = url }));
    }

    try std.testing.expect(valid_options(.{ .base_url = "https://example.com/site" }));
}
