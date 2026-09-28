const std = @import("std");
const core = @import("core.zig");

pub fn add_check(builder: *std.Build, from: core.Sources) *std.Build.Step {
    const target = builder.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });

    std.debug.assert(target.result.cpu.arch == .wasm32);
    std.debug.assert(target.result.os.tag == .wasi);

    const check = builder.addExecutable(.{
        .name = "publr-wasm-check",
        .root_module = core.add_module(builder, target, .ReleaseSmall, from),
    });

    return &check.step;
}
