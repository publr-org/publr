const std = @import("std");
const core = @import("core.zig");

pub fn add_step(builder: *std.Build, from: core.Sources) *std.Build.Step {
    const target = builder.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    std.debug.assert(target.result.cpu.arch == .wasm32);
    std.debug.assert(target.result.os.tag == .wasi);

    const debug = builder.option(bool, "browser-debug", "Build the wasm in Debug mode") orelse
        false;
    const library = core.add_module(builder, target, if (debug) .Debug else .ReleaseSmall, from);
    const module = core.add_entry(builder, "src/app/wasm.zig", library);
    const wasm = builder.addExecutable(.{ .name = "publr", .root_module = module });

    wasm.wasi_exec_model = .reactor;
    wasm.rdynamic = true;

    const install_wasm = builder.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "browser" } },
    });
    const install_files = builder.addInstallDirectory(.{
        .source_dir = builder.path("browser"),
        .install_dir = .{ .custom = "browser" },
        .install_subdir = "",
    });

    const step = builder.step("browser", "Build the in-browser demo into zig-out/browser");

    step.dependOn(&install_wasm.step);
    step.dependOn(&install_files.step);

    return step;
}
