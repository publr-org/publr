const std = @import("std");
const jit = @import("publr_jit");
const runtime = @import("runtime");
const apps_module = @import("apps");
const apps_options = @import("apps_options");
const engine = @import("../../template.zig");
const model_app = @import("../../model/app.zig");
const middleware = @import("middleware.zig");
const registry = @import("../../server/registry.zig");

pub const apps_max: u32 = apps_options.apps_max;
pub const minify: bool = apps_options.minify;
pub const engine_stamp: []const u8 = apps_options.engine_stamp;
/// Where `serve` reads each app's `public/` files unless told: `apps`, or the preset's.
pub const public_dir: []const u8 = apps_options.public_dir;
pub const assets_max: u32 = 256;

pub const File = struct { path: []const u8, data: []const u8 };

/// One compiled-in app as data: its name and mount, its templates, its generated client
/// code, its stylesheet's inputs, its interactive components and its middleware.
pub const Spec = struct {
    /// The app's id, from `app.zon`.
    name: []const u8,
    /// What the admin shows: `app.zon`'s label, else the name.
    label: []const u8,
    /// Its folder under the apps' folder, where its public files are read from.
    folder: []const u8,
    mount: model_app.Mount,
    /// The roles a visitor needs to be signed in to this app; empty for any.
    roles: []const []const u8,
    /// The plugins whose content types it reaches; null for every plugin's.
    plugins: ?[]const []const u8,
    templates: []const File,
    assets: []const File,
    tokens: jit.Theme,
    style_css: []const u8,
    interactive_classes: []const u8,
    pjsx_components: []const engine.PjsxComponent,
    pjsx_renders: []const engine.PjsxRender,
    middleware: ?middleware.Middleware,
};

/// Every compiled-in app, in the order of their folders' names.
pub const all: []const Spec = blk: {
    @setEvalBranchQuota(1_000_000);

    var specs: [apps_module.all.len]Spec = undefined;

    for (apps_module.all, 0..) |App, index| {
        specs[index] = spec_of(App);
    }

    validate(&specs);

    const final = specs;

    break :blk &final;
};

/// The generated client code (the island loader, the toolbar, PublrJS, no stores) an app
/// read from a project's folder serves when nothing of its own is compiled in.
pub const common_assets: []const File = blk: {
    @setEvalBranchQuota(100_000);

    break :blk files_of(apps_module.common_assets);
};

pub fn find(name: []const u8) ?*const Spec {
    std.debug.assert(name.len > 0);
    std.debug.assert(all.len <= apps_max);

    for (all) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) {
            return spec;
        }
    }

    return null;
}

fn spec_of(comptime App: type) Spec {
    comptime {
        std.debug.assert(@hasDecl(App, "folder"));
        std.debug.assert(@hasDecl(App, "config"));

        const config: model_app.Config = App.config;

        if (config.name.len == 0 or config.label.len > model_app.label_len_max) {
            @compileError(App.folder ++ "/app.zon: `.name` is required, `.label` 64 bytes");
        }

        return .{
            .name = config.name,
            .label = model_app.label_of(config.name, config.label),
            .folder = App.folder,
            .mount = config.mount,
            .roles = config.roles,
            .plugins = config.plugins,
            .templates = files_of(App.templates),
            .assets = files_of(App.assets),
            .tokens = jit.extendTheme(jit.default_theme, .{ .tokens = tokens_of(config.tokens) }),
            .style_css = App.style_css,
            .interactive_classes = App.interactive_classes,
            .pjsx_components = components_of(App.interactive),
            .pjsx_renders = renders_of(App.interactive),
            .middleware = middleware_of(App.middleware),
        };
    }
}

/// The build's checks, again where the data is: names, mounts, roles and the limits.
fn validate(comptime specs: []const Spec) void {
    comptime {
        std.debug.assert(apps_max > 0);
        std.debug.assert(model_app.roles_max > 0);

        if (specs.len > apps_max) {
            @compileError("more apps than -Dapps-max allows");
        }

        for (specs, 0..) |spec, index| {
            const label = "app " ++ spec.name ++ ": ";

            if (!model_app.valid_name(spec.name)) {
                @compileError(label ++ "a name is [a-z][a-z0-9_]*, 1 to 32 characters");
            }

            if (!model_app.valid_label(spec.label)) {
                @compileError(label ++ "`.label` is one line of text, at most 64 bytes");
            }

            if (!model_app.valid_mount(spec.mount)) {
                @compileError(label ++ "`.mount` is `.{ .path = \"/\" }`, a path of " ++
                    "lower-case segments under it (not /admin, /api, /auth or /_...), or " ++
                    "`.{ .subdomain = \"name\" }`");
            }

            if (spec.roles.len > model_app.roles_max) {
                @compileError(label ++ "`.roles` names at most 16 roles");
            }

            if (model_app.plugins_problem(spec.plugins)) |problem| {
                @compileError(label ++ problem);
            }

            for (spec.roles) |name| {
                if (registry.Roles.get(name) == null) {
                    @compileError(label ++ "`.roles` names " ++ name ++ ", a role neither " ++
                        "core nor a native plugin declares");
                }
            }

            if (spec.assets.len > assets_max) {
                @compileError(label ++ "too many generated assets");
            }

            for (specs[index + 1 ..]) |other| {
                if (std.mem.eql(u8, spec.name, other.name)) {
                    @compileError(label ++ "named in " ++ spec.folder ++ " and " ++
                        other.folder ++ "; an app's `.name` is its id, one per project");
                }

                if (model_app.same_place(spec.mount, other.mount)) {
                    @compileError(label ++ "mounted where app " ++ other.name ++ " is");
                }
            }
        }
    }
}

fn files_of(comptime embedded: anytype) []const File {
    comptime {
        std.debug.assert(embedded.len <= 1 << 16);

        var files: [embedded.len]File = undefined;

        for (embedded, 0..) |file, index| {
            files[index] = .{ .path = file.path, .data = file.data };
        }

        const final = files;

        return &final;
    }
}

fn tokens_of(comptime declared: []const model_app.Token) []const jit.Token {
    comptime {
        std.debug.assert(model_app.tokens_max > 0);

        if (declared.len > model_app.tokens_max) {
            @compileError("more design tokens than an app holds");
        }

        var tokens: [declared.len]jit.Token = undefined;

        for (declared, 0..) |token, index| {
            tokens[index] = .{ .name = token.name, .value = token.value };
        }

        const final = tokens;

        return &final;
    }
}

fn middleware_of(comptime Module: type) ?middleware.Middleware {
    comptime {
        std.debug.assert(@typeInfo(Module) == .@"struct");

        if (!@hasDecl(Module, "middleware")) {
            return null;
        }

        return &struct {
            fn run(request: *middleware.Request) anyerror!?middleware.Response {
                std.debug.assert(request.http.path().len > 0);

                return Module.middleware(request);
            }
        }.run;
    }
}

/// The lowered components a template can place by name. The lowering also carries every
/// design-system part they import (a `Button` with its required children); a template
/// places only a component whose props all start from a default.
fn placeable_decls(comptime Interactive: type) []const std.builtin.Type.Declaration {
    comptime {
        @setEvalBranchQuota(100_000);
        std.debug.assert(@typeInfo(Interactive) == .@"struct");

        const decls = @typeInfo(Interactive).@"struct".decls;
        var kept: [decls.len]std.builtin.Type.Declaration = undefined;
        var count: u32 = 0;

        for (decls) |decl| {
            if (placeable(@field(Interactive, decl.name))) {
                kept[count] = decl;
                count += 1;
            }
        }

        const final = kept[0..count].*;

        return &final;
    }
}

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

/// An app's interactive components as the engine sees them: names and string props read off
/// each lowered module's `Props` type. The PublrJS transport props (`publr_*`) are the
/// compiler's, not an app's.
fn components_of(comptime Interactive: type) []const engine.PjsxComponent {
    comptime {
        @setEvalBranchQuota(100_000);
        std.debug.assert(@typeInfo(Interactive) == .@"struct");

        const decls = placeable_decls(Interactive);
        var components: [decls.len]engine.PjsxComponent = undefined;

        for (decls, 0..) |decl, index| {
            components[index] = component_of(decl.name, @field(Interactive, decl.name));
        }

        const final = components;

        return &final;
    }
}

fn component_of(comptime name: []const u8, comptime Component: type) engine.PjsxComponent {
    comptime {
        std.debug.assert(name.len > 0);
        std.debug.assert(@hasDecl(Component, "Props"));

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

        return .{ .name = name, .props = &kept, .takes_children = takes_children };
    }
}

/// The same components' render functions, by the same index, wrapped to take props by name.
fn renders_of(comptime Interactive: type) []const engine.PjsxRender {
    comptime {
        std.debug.assert(@typeInfo(Interactive) == .@"struct");

        const decls = placeable_decls(Interactive);
        var renders: [decls.len]engine.PjsxRender = undefined;

        for (decls, 0..) |decl, index| {
            renders[index] = &Thunk(@field(Interactive, decl.name)).render;
        }

        const final = renders;

        return &final;
    }
}

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

test "every compiled-in app is well formed and found by its name" {
    for (all) |*spec| {
        try std.testing.expect(model_app.valid_name(spec.name));
        try std.testing.expect(model_app.valid_mount(spec.mount));
        try std.testing.expectEqual(spec, find(spec.name).?);
        try std.testing.expect(spec.assets.len > 0);
    }
}
