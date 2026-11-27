//! The version of the admin's own files (`scripts/admin_asset_version.zig`), embedded as
//! `admin_asset_version`: a hash of every file served under `/admin/assets/<version>/`.
const std = @import("std");

/// The generated files the admin serves; the runtime's files are read from publr-js.
pub const Inputs = struct {
    styles: std.Build.LazyPath,
    stores: std.Build.LazyPath,
    class_book: std.Build.LazyPath,
};

/// The version file, which the SDK archive also carries: an installed plugin's views draw with
/// the admin's layouts, which link these files.
pub fn add(builder: *std.Build, module: *std.Build.Module, inputs: Inputs) std.Build.LazyPath {
    std.debug.assert(module.root_source_file != null);
    std.debug.assert(builder.root.sub_path.len == 0);

    const tool = builder.addExecutable(.{
        .name = "admin_asset_version",
        .root_module = builder.createModule(.{
            .root_source_file = builder.path("scripts/admin_asset_version.zig"),
            .target = builder.graph.host,
            .optimize = .debug,
        }),
    });
    const run = builder.addRunArtifact(tool);
    const version = run.addOutputFileArg("admin_asset_version.zig");

    run.addFileArg(inputs.styles);
    run.addFileArg(inputs.stores);
    run.addFileArg(inputs.class_book);

    inline for (@import("../src/ui/client_files.zig").names) |name| {
        run.addFileArg(builder.path("../publr-js/dist/" ++ name ++ ".js"));
    }

    run.addDirectoryArg(builder.dependency("publr_editor", .{}).namedLazyPath("admin"));
    module.addAnonymousImport("admin_asset_version", .{
        .root_source_file = version,
    });

    return version;
}
