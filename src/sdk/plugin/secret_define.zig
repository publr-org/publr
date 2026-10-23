//! A plugin's secrets, as `.secrets` declares them: a struct of `publr.Secret` fields, each
//! field's name the secret's, its `///` the label people see and where to find it. Not a
//! permission: declaring is the request. The plugin uses exactly what it declares; a
//! `{secret:NAME}` its code writes without declaring it fails the build.
const std = @import("std");
const plugin_define = @import("define.zig");
const secrets = @import("../../model/secrets.zig");

pub const Declared = secrets.Declared;

/// Each secret the plugin declares, with its label and help from its `///`.
pub fn declared_of(comptime Plugin: type) []const Declared {
    comptime {
        if (!plugin_define.has(Plugin, "secrets")) {
            return &.{};
        }

        const Secrets = Plugin.options.secrets;
        const plugin = Plugin.manifest.name;
        var list: []const Declared = &.{};

        std.debug.assert(plugin.len > 0);

        if (@TypeOf(Secrets) != type or @typeInfo(Secrets) != .@"struct") {
            @compileError("plugin " ++ plugin ++ ": `.secrets` is a struct of publr.Secret " ++
                "fields");
        }

        if (std.meta.fields(Secrets).len > secrets.declared_max) {
            @compileError("plugin " ++ plugin ++ ": more than 32 secrets");
        }

        for (std.meta.fields(Secrets)) |field| {
            list = list ++ [_]Declared{declared_one(Plugin, Secrets, field)};
        }

        const done = list;

        return done;
    }
}

fn declared_one(
    comptime Plugin: type,
    comptime Secrets: type,
    comptime field: std.builtin.Type.StructField,
) Declared {
    comptime {
        const plugin = Plugin.manifest.name;
        const key = @typeName(Secrets) ++ "." ++ field.name;
        const is_secret = @typeInfo(field.type) == .@"struct" and
            std.meta.fields(field.type).len == 0 and
            std.mem.endsWith(u8, @typeName(field.type), "Secret");

        std.debug.assert(plugin.len > 0);

        if (!is_secret) {
            @compileError("plugin " ++ plugin ++ ": secret " ++ field.name ++ " is a " ++
                "publr.Secret");
        }

        if (!secrets.valid_name(field.name)) {
            @compileError("plugin " ++ plugin ++ ": secret " ++ field.name ++ " is named " ++
                "like an environment variable: capitals, digits and underscores");
        }

        const label = plugin_define.first(Plugin.docs, key) orelse "";

        if (label.len == 0) {
            @compileError("plugin " ++ plugin ++ ": secret " ++ field.name ++ " needs a " ++
                "`///` comment: its label, then where to find it");
        }

        return .{
            .name = field.name,
            .label = label,
            .help = plugin_define.rest(Plugin.docs, key) orelse "",
        };
    }
}

/// Fails the build when the plugin's code writes a `{secret:NAME}` it did not declare, or
/// declares secrets without asking for `http.fetch`, the only way one is sent.
pub fn check(comptime Plugin: type) void {
    comptime {
        const plugin = Plugin.manifest.name;
        const declared = declared_of(Plugin);
        var names: []const []const u8 = &.{};

        std.debug.assert(plugin.len > 0);

        for (declared) |secret| {
            names = names ++ [_][]const u8{secret.name};
        }

        if (@hasDecl(Plugin.docs, "secrets_written")) {
            if (secrets.undeclared(names, &Plugin.docs.secrets_written)) |name| {
                @compileError("plugin " ++ plugin ++ ": `{secret:" ++ name ++ "}` is not " ++
                    "declared in `.secrets`");
            }
        }

        if (declared.len > 0 and !asks_fetch(Plugin)) {
            @compileError("plugin " ++ plugin ++ ": secrets are sent by `http.fetch`; ask " ++
                "for it in `.permissions`");
        }
    }
}

fn asks_fetch(comptime Plugin: type) bool {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        if (!plugin_define.has(Plugin, "permissions")) {
            return false;
        }

        for (plugin_define.get(Plugin, "permissions")) |ask| {
            if (std.mem.eql(u8, ask.key, "http.fetch")) {
                return true;
            }
        }

        return false;
    }
}

const TestSecrets = struct {
    SUPPLIER_API_KEY: @import("../../publr.zig").Secret,
};

const TestPlugin = struct {
    pub const manifest = .{
        .name = "supplier",
        .version = "0.1.0",
    };
    pub const options = .{
        .secrets = TestSecrets,
        .permissions = .{.{
            .key = "http.fetch",
            .domains = &.{"api.supplier.com"},
            .reason = "Reads prices",
        }},
    };
    pub const source = struct {};
    pub const docs = plugin_define.Words(.{.{
        @typeName(TestSecrets) ++ ".SUPPLIER_API_KEY",
        "Supplier API key\n\nIn the supplier's dashboard under Settings › API › Keys.",
    }});
    pub const secrets_written = [_][]const u8{"SUPPLIER_API_KEY"};
};

test "declared secrets carry their label and where to find them" {
    const declared = comptime declared_of(TestPlugin);

    comptime check(TestPlugin);
    try std.testing.expectEqual(@as(usize, 1), declared.len);
    try std.testing.expectEqualStrings("SUPPLIER_API_KEY", declared[0].name);
    try std.testing.expectEqualStrings("Supplier API key", declared[0].label);
    try std.testing.expectEqualStrings(
        "In the supplier's dashboard under Settings › API › Keys.",
        declared[0].help,
    );
    try std.testing.expect(secrets.undeclared(&.{"SUPPLIER_API_KEY"}, &.{"OTHER_KEY"}) != null);
}
