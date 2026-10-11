//! `design.save_system`: an app's design system, its tokens and fonts written into its
//! `app.zon` (the rest of the file kept as it is) and the structure over them into its
//! `design/system.zon`, through `apps.write`, then loaded live.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const apps = @import("../apps.zig");
const model_app = @import("../../model/app.zig");
const design = @import("../../model/design.zig");
const zon_fields = @import("../../model/app/zon_fields.zig");
const design_system = @import("../../model/design/system.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const SaveSystem = struct {
    pub const name = "design.save_system";
    pub const description = "Write an app's design tokens and fonts into its app.zon, live";
    pub const details =
        \\Administrators only, and not a device that may save drafts only. `tokens` replaces
        \\the app's `.tokens` and `fonts` its `.fonts`, whole; everything else in `app.zon`
        \\stays as written. A token's name is lowercase letters, digits and `-`, starting
        \\with a letter; its value one CSS value (no `;`, `{`, `}` or line break). A font is a
        \\family with an `https://` stylesheet, or the files the site hosts (`faces`, each a
        \\media path or `https://`). `system`, when given, replaces `design/system.zon`: the
        \\color roles and contexts, the font definitions, the type scale, the icons and the
        \\blocks' starting documents. Once written the apps are loaded again; when
        \\they do not load, it fails with `NotLoaded` and why, and the file stays written.
        \\Not found when no app has that `.name`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        app: []const u8,
        tokens: []const model_app.Token = &.{},
        fonts: []const model_app.Font = &.{},
        system: ?design_system.System = null,
    };
    pub const Out = struct {
        path: []const u8,
        tokens: u32,
        fonts: u32,
        system: []const u8 = "",
    };
    pub const example: In = .{
        .app = "www",
        .tokens = &.{.{
            .name = "color-brand",
            .value = "#2f5d54",
        }},
        .fonts = &.{.{
            .family = "Inter",
            .url = "https://fonts.googleapis.com/css2?family=Inter",
        }},
    };
    pub const example_out: Out = .{
        .path = "www/app.zon",
        .tokens = 1,
        .fonts = 1,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .app = "The app's `.name`",
        .tokens = "Every token, `{name, value}`, in order: the app's whole `.tokens`",
        .fonts = "Every font, `{family, url}` or `{family, faces}`: the app's whole `.fonts`",
        .system = "The structure over the tokens: `design/system.zon`, whole; null keeps it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .path = "The file written, `<folder>/app.zon`",
        .tokens = "How many tokens it holds now",
        .fonts = "How many fonts it holds now",
        .system = "The structure's file when one was written, `<folder>/design/system.zon`",
    };

    pub fn run(ctx: *Ctx, in: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try check(in);

        const found = try find_zon(ctx, in.app);
        const arena = ctx.arena;
        const with_tokens = zon_fields.replace(arena, found.content, "tokens", try tokens_zon(
            arena,
            in.tokens,
        )) catch return error.Invalid;
        const content = zon_fields.replace(arena, with_tokens, "fonts", try fonts_zon(
            arena,
            in.fonts,
        )) catch return error.Invalid;

        if (!std.mem.eql(u8, (try parsed(arena, content)).name, in.app)) {
            return error.Invalid;
        }

        _ = try registry.SDK.dispatch(ctx, apps.Write, .{
            .path = found.path,
            .content = content,
        });

        var written: []const u8 = "";

        if (in.system) |structure| {
            written = try write_structure(ctx, found.path, structure);
        }

        std.debug.assert(content.len > 0);

        return .{
            .path = found.path,
            .tokens = @intCast(in.tokens.len),
            .fonts = @intCast(in.fonts.len),
            .system = written,
        };
    }

    /// Once the file is kept, the apps are read again: the new design is live.
    pub fn committed(ctx: *Ctx, in: In, out: Out) Error!void {
        std.debug.assert(ctx.db.transaction_depth == 0);
        std.debug.assert(out.path.len > 0 and in.app.len > 0);

        _ = try registry.SDK.dispatch(ctx, apps.Load, .{});
    }
};

fn check(in: SaveSystem.In) Error!void {
    std.debug.assert(model_app.tokens_max > 0);

    const too_many = in.tokens.len > model_app.tokens_max or in.fonts.len > model_app.fonts_max;

    if (!model_app.valid_name(in.app) or too_many) {
        return error.Invalid;
    }

    for (in.tokens) |token| {
        if (!design.valid_token_name(token.name) or !design.valid_token_value(token.value)) {
            return error.Invalid;
        }
    }

    for (in.fonts) |font| {
        if (!valid_font(font)) {
            return error.Invalid;
        }
    }

    if (in.system) |structure| {
        if (!design_system.valid(structure)) {
            return error.Invalid;
        }
    }
}

/// A stylesheet font, or a hosted one: a family whose faces are all files this site or
/// `https://` serves.
fn valid_font(font: model_app.Font) bool {
    std.debug.assert(model_app.font_faces_max > 0);
    std.debug.assert(font.faces.len < 1 << 24);

    if (font.faces.len == 0) {
        return design.valid_font(font.family, font.url);
    }

    const stylesheet_ok = font.url.len == 0 or design.valid_font(font.family, font.url);

    if (!stylesheet_ok or font.faces.len > model_app.font_faces_max) {
        return false;
    }

    if (!design.valid_font_family(font.family)) {
        return false;
    }

    for (font.faces) |face| {
        if (!design.valid_font_face(face.src, face.weight_min, face.weight_max)) {
            return false;
        }
    }

    return true;
}

/// Writes `design/system.zon` beside the app's `app.zon`; answers its path.
fn write_structure(
    ctx: *Ctx,
    zon_path: []const u8,
    structure: design_system.System,
) Error![]const u8 {
    std.debug.assert(std.mem.endsWith(u8, zon_path, "/app.zon"));
    std.debug.assert(design_system.valid(structure));

    const folder = zon_path[0 .. zon_path.len - "/app.zon".len];
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/{s}", .{
        folder,
        design_system.file_name,
    });
    const content = try design_system.to_zon(ctx.arena, structure);

    _ = try registry.SDK.dispatch(ctx, apps.Write, .{
        .path = path,
        .content = content,
    });

    return path;
}

pub const Found = struct {
    path: []const u8,
    content: []const u8,
};

/// The `app.zon` whose `.name` is `app`, whatever folder holds it.
pub fn find_zon(ctx: *Ctx, app: []const u8) Error!Found {
    std.debug.assert(app.len > 0);
    std.debug.assert(app.len <= model_app.name_len_max);

    const listed = try registry.SDK.dispatch(ctx, apps.Files, .{});

    for (listed.files) |file| {
        const slash = std.mem.indexOfScalar(u8, file.path, '/') orelse continue;

        if (!std.mem.eql(u8, file.path[slash + 1 ..], "app.zon")) {
            continue;
        }

        const read = try registry.SDK.dispatch(ctx, apps.Read, .{
            .path = file.path,
        });
        const config = parsed(ctx.arena, read.content) catch continue;

        if (std.mem.eql(u8, config.name, app)) {
            return .{
                .path = file.path,
                .content = read.content,
            };
        }
    }

    return error.NotFound;
}

pub fn parsed(arena: std.mem.Allocator, content: []const u8) Error!model_app.Config {
    std.debug.assert(content.len < 1 << 31);

    const text = arena.dupeZ(u8, content) catch return error.OutOfMemory;

    return std.zon.parse.fromSliceAlloc(model_app.Config, arena, text, null, .{}) catch {
        return error.Invalid;
    };
}

fn tokens_zon(arena: std.mem.Allocator, tokens: []const model_app.Token) Error![]const u8 {
    std.debug.assert(tokens.len <= model_app.tokens_max);

    if (tokens.len == 0) {
        return ".{}";
    }

    var out: std.Io.Writer.Allocating = .init(arena);

    out.writer.writeAll(".{\n") catch return error.OutOfMemory;

    for (tokens) |token| {
        out.writer.print("        .{{ .name = \"{f}\", .value = \"{f}\" }},\n", .{
            std.zig.fmtString(token.name),
            std.zig.fmtString(token.value),
        }) catch return error.OutOfMemory;
    }

    out.writer.writeAll("    }") catch return error.OutOfMemory;

    return out.written();
}

fn fonts_zon(arena: std.mem.Allocator, fonts: []const model_app.Font) Error![]const u8 {
    std.debug.assert(fonts.len <= model_app.fonts_max);

    if (fonts.len == 0) {
        return ".{}";
    }

    var out: std.Io.Writer.Allocating = .init(arena);

    out.writer.writeAll(".{\n") catch return error.OutOfMemory;

    for (fonts) |font| {
        out.writer.print("        .{{ .family = \"{f}\", .url = \"{f}\"", .{
            std.zig.fmtString(font.family),
            std.zig.fmtString(font.url),
        }) catch return error.OutOfMemory;

        if (font.faces.len > 0) {
            try faces_zon(&out.writer, font.faces);
        }

        out.writer.writeAll(" },\n") catch return error.OutOfMemory;
    }

    out.writer.writeAll("    }") catch return error.OutOfMemory;

    return out.written();
}

/// A hosted family's faces, inline in its `.fonts` entry.
fn faces_zon(writer: *std.Io.Writer, faces: []const model_app.FontFace) Error!void {
    std.debug.assert(faces.len > 0);
    std.debug.assert(faces.len <= model_app.font_faces_max);

    writer.writeAll(", .faces = .{ ") catch return error.OutOfMemory;

    for (faces) |face| {
        writer.print(".{{ .weight_min = {d}, .weight_max = {d}, .italic = {}, " ++
            ".src = \"{f}\" }}, ", .{
            face.weight_min,
            face.weight_max,
            face.italic,
            std.zig.fmtString(face.src),
        }) catch return error.OutOfMemory;
    }

    writer.writeAll("}") catch return error.OutOfMemory;
}

test "the zon written for tokens and fonts reads back as an app.zon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = "// Mine.\n.{\n    .name = \"www\",\n    .mount = .{ .path = \"/\" },\n}\n";
    const tokens = [_]model_app.Token{.{
        .name = "font-sans",
        .value = "\"Inter\", sans",
    }};
    const fonts = [_]model_app.Font{.{
        .family = "Inter",
        .url = "https://f.test/inter.css",
    }};
    const tokens_text = try tokens_zon(arena, &tokens);
    const with_tokens = try zon_fields.replace(arena, source, "tokens", tokens_text);
    const fonts_text = try fonts_zon(arena, &fonts);
    const written = try zon_fields.replace(arena, with_tokens, "fonts", fonts_text);
    const config = try parsed(arena, written);

    try std.testing.expect(std.mem.startsWith(u8, written, "// Mine.\n.{\n    .name = \"www\","));
    try std.testing.expectEqualStrings("\"Inter\", sans", config.tokens[0].value);
    try std.testing.expectEqualStrings("https://f.test/inter.css", config.fonts[0].url);
    try std.testing.expectEqual(@as(usize, 0), (try parsed(arena, try zon_fields.replace(
        arena,
        written,
        "fonts",
        try fonts_zon(arena, &.{}),
    ))).fonts.len);
    try std.testing.expectError(error.Invalid, check(.{
        .app = "www",
        .fonts = &.{.{
            .family = "Inter",
            .url = "http://f.test/inter.css",
        }},
    }));
    try std.testing.expectError(error.Invalid, check(.{
        .app = "www",
        .tokens = &.{.{
            .name = "color",
            .value = "red; }",
        }},
    }));
}

test "a hosted family's faces are written inline and checked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = ".{\n    .name = \"www\",\n    .mount = .{ .path = \"/\" },\n}\n";
    const faces = [_]model_app.FontFace{
        .{
            .src = "/media/regular.woff2",
        },
        .{
            .weight_min = 100,
            .weight_max = 900,
            .italic = true,
            .src = "/media/italic.woff2",
        },
    };
    const fonts = [_]model_app.Font{.{
        .family = "Inferi",
        .faces = &faces,
    }};
    const written = try zon_fields.replace(arena, source, "fonts", try fonts_zon(arena, &fonts));
    const config = try parsed(arena, written);

    try std.testing.expectEqual(@as(usize, 2), config.fonts[0].faces.len);
    try std.testing.expectEqual(@as(u32, 900), config.fonts[0].faces[1].weight_max);
    try std.testing.expect(config.fonts[0].faces[1].italic);
    try check(.{
        .app = "www",
        .fonts = &fonts,
    });
    try std.testing.expectError(error.Invalid, check(.{
        .app = "www",
        .fonts = &.{.{
            .family = "Inferi",
            .faces = &.{.{
                .src = "/media/a.woff2);x{",
            }},
        }},
    }));
    try std.testing.expectError(error.Invalid, check(.{
        .app = "www",
        .system = .{
            .roles = &.{.{
                .key = "Not A Key",
                .label = "Surface",
            }},
        },
    }));
}
