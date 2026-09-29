const std = @import("std");
const report = @import("../../lib/report.zig");
const jit = @import("publr_jit");
const engine = @import("../../template.zig");
const deps = @import("../../lib/deps.zig");
const model_app = @import("../../model/app.zig");
const spec_module = @import("spec.zig");
const fingerprint = @import("fingerprint.zig");
const middleware = @import("middleware.zig");

pub const Spec = spec_module.Spec;
pub const Asset = fingerprint.Asset;
pub const version_len = fingerprint.version_len;
pub const assets_max = fingerprint.assets_max;
pub const minify = spec_module.minify;
pub const output_dir_default = "output";
pub const apps_dir_default = spec_module.public_dir;
pub const base_url_default = "http://127.0.0.1:8080";
pub const url_len_max: u32 = 2048;

const preflight_css = @embedFile("apps_preflight_css");

pub const Options = struct {
    /// Where every app's build goes, one folder each: `output/<app>/`.
    output_dir: []const u8 = output_dir_default,
    /// The project's public address; an app's own is derived from it and its mount.
    base_url: []const u8 = base_url_default,
    /// Where each app's `public/` files are read from, `<apps_dir>/<app>/public`.
    apps_dir: []const u8 = apps_dir_default,
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

    if (options.output_dir.len == 0 or options.apps_dir.len == 0) {
        return false;
    }

    if (options.base_url.len > url_len_max / 2) {
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

/// One app as the server holds it: its templates loaded by the engine, its stylesheet
/// compiled by the JIT, its generated client code under one fingerprint, and its output
/// folder. Public files stay on disk outside this state.
pub const App = struct {
    spec: *const Spec,
    gpa: std.mem.Allocator,
    io: std.Io,
    index: *deps.Index,
    /// The app's templates compiled; null for an app with none, which only has middleware.
    program: ?*engine.Program,
    css: []const u8,
    /// Changes when generated client code or the compiled stylesheet changes.
    version: [version_len]u8,
    /// The embedded assets, relative imports between the JS files fingerprinted.
    assets: []const Asset,
    /// What `stores.js` imports, transitively: the page preloads them beside it.
    stores_imports: []const []const u8,
    /// Where the app answers: `https://example.com/newsletter`, `https://app.example.com`.
    url: []const u8,
    output: ?std.Io.Dir = null,
    options: Options,
    /// What a build depends on besides the records: the templates, `version` (the
    /// stylesheet and the assets) and the app's address. A folder built under another
    /// stamp is another app, rebuilt whole.
    build_stamp: [version_len]u8,
    /// `Publr.build.now()`: when the app was last built.
    built_at: i64,
    /// A failed static build must not expose partial output or attempt live rendering.
    build_ready: bool = true,
    retry_revision: u64 = 0,
    /// Asked before anything else on the app's paths: its `middleware.zig`.
    middleware: ?middleware.Middleware,

    pub const Error = engine.LoadError || jit.CompileError || std.mem.Allocator.Error ||
        error{InvalidOptions};

    /// Loads the app's templates (one that does not load is a startup failure naming the
    /// template) and compiles its stylesheet.
    pub fn init(
        app: *App,
        spec: *const Spec,
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
        std.debug.assert(spec.name.len > 0);

        app.* = .{
            .spec = spec,
            .gpa = gpa,
            .io = io,
            .index = index,
            .program = null,
            .css = "",
            .version = undefined,
            .assets = &.{},
            .stores_imports = &.{},
            .url = "",
            .options = options,
            .build_stamp = undefined,
            .built_at = now_ms,
            .middleware = spec.middleware,
        };
        try app.load();
        errdefer app.unload();

        app.version = fingerprint.stamp(spec, app.css);
        app.assets = try fingerprint.rewrite(gpa, spec.assets, &app.version);
        errdefer fingerprint.free(gpa, app.assets);

        app.stores_imports = try fingerprint.imports_of(gpa, app.assets, "stores.js");
        errdefer gpa.free(app.stores_imports);

        app.url = try url_of(gpa, options.base_url, spec.mount);
        app.build_stamp = fingerprint.build_stamp(spec, &app.version, app.url);

        std.debug.assert(app.css.len > 0);
    }

    /// The templates and the stylesheet.
    fn load(app: *App) Error!void {
        std.debug.assert(app.program == null);
        std.debug.assert(app.css.len == 0);

        if (app.spec.templates.len > 0) {
            var arena_state = std.heap.ArenaAllocator.init(app.gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            var diagnostic: engine.Diagnostic = .{ .arena = arena };
            const loaded = engine.load(
                app.gpa,
                try sources(arena, app.spec),
                engine_options(app.spec),
                &diagnostic,
            );

            app.program = loaded catch |err| {
                if (app.options.diagnostic) |reason| {
                    reason.set("[{s}] {s}", .{ app.spec.name, diagnostic.message });
                }

                return err;
            };
        }

        errdefer app.unload();

        app.css = try compile_css(app.gpa, app.spec, app.program);
    }

    fn unload(app: *App) void {
        std.debug.assert(app.spec.name.len > 0);

        if (app.css.len > 0) {
            app.gpa.free(app.css);
            app.css = "";
        }

        if (app.program) |program| {
            destroy(app.gpa, program);
            app.program = null;
        }
    }

    pub fn deinit(app: *App) void {
        std.debug.assert(app.css.len > 0);
        std.debug.assert(app.url.len > 0);

        if (app.output) |*dir| {
            dir.close(app.io);
        }

        app.gpa.free(app.url);
        app.gpa.free(app.stores_imports);
        fingerprint.free(app.gpa, app.assets);
        app.unload();
        app.* = undefined;
    }

    /// The compiled templates of an app that has pages.
    pub fn pages(app: *const App) *engine.Program {
        std.debug.assert(app.css.len > 0);
        std.debug.assert(app.program != null);

        return app.program.?;
    }

    /// What the app's own URLs start with on its host: `/newsletter`, or nothing.
    pub fn base(app: *const App) []const u8 {
        std.debug.assert(app.spec.name.len > 0);

        return model_app.base_path(app.spec.mount);
    }

    /// Opens (creating) `<output>/<app>/`: the build writes there and `serve` reads.
    pub fn open_output(app: *App) !void {
        std.debug.assert(app.options.output_dir.len > 0);
        std.debug.assert(app.output == null);

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = try app.output_path(&buffer);

        app.output = try std.Io.Dir.cwd().createDirPathOpen(app.io, path, .{});
    }

    /// Opens `<output>/<app>/` only when a build already exists there.
    pub fn open_existing_output(app: *App) void {
        std.debug.assert(app.options.output_dir.len > 0);
        std.debug.assert(app.output == null);

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path = app.output_path(&buffer) catch return;

        app.output = std.Io.Dir.cwd().openDir(app.io, path, .{}) catch null;
    }

    fn output_path(app: *const App, buffer: []u8) ![]const u8 {
        std.debug.assert(buffer.len > 0);
        std.debug.assert(app.spec.name.len > 0);

        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ app.options.output_dir, app.spec.name });
    }

    /// `<apps_dir>/<app>/public`, where the app's public files are read from.
    pub fn public_dir(app: *const App, arena: std.mem.Allocator) ![]const u8 {
        std.debug.assert(app.options.apps_dir.len > 0);
        std.debug.assert(app.spec.name.len > 0);

        return std.fmt.allocPrint(arena, "{s}/{s}/public", .{
            app.options.apps_dir,
            app.spec.name,
        });
    }

    pub fn asset(app: *const App, path: []const u8) ?[]const u8 {
        std.debug.assert(path.len > 0);
        std.debug.assert(app.assets.len <= assets_max);

        return fingerprint.find(app.assets, path);
    }

    /// Whether `token` is this app's fingerprint: bytes under that URL can never change.
    pub fn fingerprinted(app: *const App, token: ?[]const u8) bool {
        std.debug.assert(app.version.len == version_len);
        std.debug.assert(app.css.len > 0);

        const asked = token orelse return false;

        return std.mem.eql(u8, asked, &app.version);
    }
};

fn url_of(gpa: std.mem.Allocator, base_url: []const u8, mount: model_app.Mount) ![]const u8 {
    std.debug.assert(base_url.len > 0);
    std.debug.assert(model_app.valid_mount(mount));

    var buffer: [url_len_max]u8 = undefined;
    const written = model_app.url(&buffer, base_url, mount) orelse return error.InvalidOptions;

    return gpa.dupe(u8, written);
}

pub fn engine_options(spec: *const Spec) engine.Options {
    std.debug.assert(spec.name.len > 0);
    std.debug.assert(spec.pjsx_components.len == spec.pjsx_renders.len);

    return .{ .minify = minify, .pjsx = spec.pjsx_components };
}

/// Compiles every app and its stylesheet as `serve` would, with no database: the build runs
/// it (`publr check-apps`), so a template the engine refuses fails the build rather than
/// the first start. Null when all compile; else why not, in `arena`.
pub fn check_apps(gpa: std.mem.Allocator, arena: std.mem.Allocator) !?[]const u8 {
    std.debug.assert(spec_module.all.len <= spec_module.apps_max);

    return check_specs(gpa, arena, spec_module.all);
}

/// `check_apps` for any apps: the ones a project's folder holds (`publr apps load`).
pub fn check_specs(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    specs: []const Spec,
) !?[]const u8 {
    std.debug.assert(engine.templates_max > 0);
    std.debug.assert(specs.len <= spec_module.apps_max);

    for (specs) |*spec| {
        if (try check_app(gpa, arena, spec)) |problem| {
            return try std.fmt.allocPrint(arena, "[{s}] {s}", .{ spec.name, problem });
        }
    }

    return null;
}

fn check_app(gpa: std.mem.Allocator, arena: std.mem.Allocator, spec: *const Spec) !?[]const u8 {
    std.debug.assert(spec.name.len > 0);
    std.debug.assert(spec.assets.len > 0);

    var program: ?*engine.Program = null;
    defer if (program) |loaded| destroy(gpa, loaded);

    if (spec.templates.len > 0) {
        var diagnostic: engine.Diagnostic = .{ .arena = arena };
        const options = engine_options(spec);

        program = engine.load(gpa, try sources(arena, spec), options, &diagnostic) catch |err| {
            const message = if (diagnostic.message.len > 0)
                diagnostic.message
            else
                @errorName(err);

            return message;
        };
    }

    const css = compile_css(gpa, spec, program) catch |err| {
        return try std.fmt.allocPrint(arena, "the stylesheet: {s}", .{@errorName(err)});
    };

    gpa.free(css);

    return null;
}

fn destroy(gpa: std.mem.Allocator, program: *engine.Program) void {
    std.debug.assert(program.templates.len > 0);

    program.deinit();
    gpa.destroy(program);
}

/// The app's embedded templates as the engine's sources.
fn sources(arena: std.mem.Allocator, spec: *const Spec) ![]const engine.Source {
    std.debug.assert(engine.templates_max > 0);
    std.debug.assert(spec.templates.len > 0);

    if (spec.templates.len > engine.templates_max) {
        return error.TooManyTemplates;
    }

    const list = try arena.alloc(engine.Source, spec.templates.len);

    for (spec.templates, list) |file, *source| {
        source.* = .{ .rel = file.path, .source = file.data, .origin = .app };
    }

    return list;
}

/// Preflight, the app's own `style.css`, then the JIT over every class its templates and
/// its interactive components name. Owned by the caller.
pub fn compile_css(
    gpa: std.mem.Allocator,
    spec: *const Spec,
    program: ?*const engine.Program,
) ![]const u8 {
    std.debug.assert(preflight_css.len > 0);
    std.debug.assert(spec.name.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var classes: std.ArrayList([]const u8) = .empty;

    if (program) |loaded| {
        try classes.appendSlice(arena, loaded.classes);
    }

    var tokens = std.mem.tokenizeAny(u8, spec.interactive_classes, " \t\r\n");

    while (tokens.next()) |class| {
        try classes.append(arena, class);
    }

    const utilities = try jit.compile(arena, spec.tokens, classes.items, .{ .minify = minify });
    const separator: []const u8 = if (minify) "" else "\n";
    const parts = [_][]const u8{ preflight_css, separator, spec.style_css, separator, utilities };

    return std.mem.concat(gpa, u8, &parts);
}

test "options reject empty paths and malformed base addresses" {
    try std.testing.expect(!valid_options(.{ .output_dir = "" }));
    try std.testing.expect(!valid_options(.{ .apps_dir = "" }));

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
