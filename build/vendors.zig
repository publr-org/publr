const std = @import("std");

pub const Pin = struct {
    name: []const u8,
    version: []const u8,
    upstream: []const u8,
    archive: []const u8,
    keep: []const []const u8,
};

pub const pins = [_]Pin{
    .{
        .name = "stb",
        .version = "2c980bb59875b0d32144a71867fbdebb2f77cd20",
        .upstream = "https://github.com/nothings/stb/archive/" ++
            "2c980bb59875b0d32144a71867fbdebb2f77cd20.tar.gz",
        .archive = "stb-2c980bb59875b0d32144a71867fbdebb2f77cd20.tar.gz",
        .keep = &.{ "stb_image.h", "stb_image_resize2.h", "stb_image_write.h", "LICENSE" },
    },
    .{
        .name = "libwebp",
        .version = "1.6.0",
        .upstream = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/" ++
            "libwebp-1.6.0.tar.gz (+ .asc signature)",
        .archive = "libwebp-1.6.0.tar.gz",
        .keep = &.{ "src", "sharpyuv", "COPYING", "PATENTS", "AUTHORS" },
    },
};

pub fn add_cache_check_step(builder: *std.Build) void {
    std.debug.assert(pins.len > 0);
    std.debug.assert(builder.graph.zig_exe.len > 0);

    const run = builder.addRunArtifact(vendor_tool(builder));

    run.addArgs(&.{ "cache-check", builder.graph.zig_exe, builder.pathFromRoot(".") });
    run.has_side_effects = true;

    const step = builder.step("vendor-cache-check", "Prove a no-op build recompiles no vendor C");

    step.dependOn(&run.step);
}

pub fn add_import_step(builder: *std.Build) void {
    std.debug.assert(pins.len > 0);

    const archives_dir = builder.option(
        []const u8,
        "archives",
        "Directory holding the upstream archives",
    ) orelse ".vendor-archives";
    const step = builder.step(
        "vendor-import",
        "Re-import vendor/ from locally verified upstream archives",
    );
    const importer = vendor_tool(builder);

    std.debug.assert(archives_dir.len > 0);

    for (pins) |pin| {
        const archive_relative = builder.fmt("{s}/{s}", .{ archives_dir, pin.archive });
        const archive = builder.pathFromRoot(archive_relative);
        const run = builder.addRunArtifact(importer);

        run.addArg("import");
        run.addArg(archive);
        run.addArg(builder.pathFromRoot(builder.fmt("vendor/{s}", .{pin.name})));
        run.addArgs(&.{ pin.name, pin.version, pin.upstream });
        run.addArgs(pin.keep);
        run.has_side_effects = true;

        step.dependOn(&run.step);
    }
}

const libwebp_dirs = [_][]const u8{ "src/dec", "src/dsp", "src/enc", "src/utils", "sharpyuv" };
const libwebp_files_max: u32 = 512;

const stb_impl_c =
    \\#define STB_IMAGE_IMPLEMENTATION
    \\#define STB_IMAGE_RESIZE_IMPLEMENTATION
    \\#define STB_IMAGE_WRITE_IMPLEMENTATION
    \\#define STBI_NO_STDIO
    \\#define STBI_WRITE_NO_STDIO
    \\#include "stb_image.h"
    \\#include "stb_image_resize2.h"
    \\#include "stb_image_write.h"
    \\
;

pub fn add_library(builder: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    std.debug.assert(pins.len > 0);
    std.debug.assert(libwebp_dirs.len > 0);

    const lib = builder.addLibrary(.{
        .name = "publr_vendors",
        .linkage = .static,
        .root_module = builder.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });

    const stb_impl = builder.addWriteFiles().add("stb_impl.c", stb_impl_c);
    const module = lib.root_module;

    module.addIncludePath(builder.path("vendor/stb"));
    module.addCSourceFile(.{
        .file = stb_impl,
        .flags = &.{},
    });
    module.addIncludePath(builder.path("vendor/libwebp"));
    module.addCSourceFiles(.{
        .root = builder.path("vendor/libwebp"),
        .files = libwebp_sources(builder),
        .flags = &.{},
    });

    return lib;
}

pub fn add_include_paths(builder: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(builder.path("vendor/stb"));
    module.addIncludePath(builder.path("vendor/libwebp"));
}

fn libwebp_sources(builder: *std.Build) []const []const u8 {
    const io = builder.graph.io;
    const root = std.Io.Dir.cwd().openDir(io, builder.pathFromRoot("vendor/libwebp"), .{}) catch
        @panic("vendor/libwebp missing: run `zig build vendor-import`");

    var files = std.ArrayList([]const u8).empty;

    for (libwebp_dirs) |dir_name| {
        const dir = root.openDir(io, dir_name, .{
            .iterate = true,
        }) catch
            @panic("libwebp dir missing");
        var iterator = dir.iterate();

        while (iterator.next(io) catch @panic("libwebp dir unreadable")) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            if (!std.mem.endsWith(u8, entry.name, ".c")) {
                continue;
            }
            if (files.items.len == libwebp_files_max) {
                @panic("libwebp has too many sources");
            }

            const file = builder.fmt("{s}/{s}", .{ dir_name, entry.name });

            files.append(builder.allocator, file) catch @panic("OOM");
        }
    }

    std.debug.assert(files.items.len > 100);
    std.debug.assert(files.items.len <= libwebp_files_max);
    std.mem.sort([]const u8, files.items, {}, string_less_than);

    return files.items;
}

fn string_less_than(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn vendor_tool(builder: *std.Build) *std.Build.Step.Compile {
    std.debug.assert(builder.build_root.path != null);
    std.debug.assert(builder.graph.zig_exe.len > 0);

    return builder.addExecutable(.{
        .name = "vendor",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/vendor.zig"),
            .target = builder.graph.host,
            .optimize = .Debug,
        }),
    });
}
