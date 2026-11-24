//! A module on its way in: its pieces received into the uploads folder, the upload dropped,
//! and the file staged as a module once it is known to load.
const std = @import("std");
const wasm = @import("publr_wasm");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const files_module = @import("files.zig");
const Loaded = @import("loaded.zig").Loaded;
const sandboxed_plugins = @import("../sandboxed_plugins.zig");
const modifying = @import("modifying.zig");
const hooks_many = @import("hooks_many.zig");
const Host = sandboxed_plugins.Host;
const Target = sandboxed_plugins.Target;
const hash_len = files_module.hash_len;
const sandboxed_plugins_max = sandboxed_plugins.sandboxed_plugins_max;
const Passed = sdk.sandboxed_plugins.Passed;
const interface = @import("interface.zig");

const host_of = interface.host_of;

pub fn receive(
    context: *anyopaque,
    file: []const u8,
    offset: u64,
    bytes: []const u8,
    last: bool,
) sdk.Error!u64 {
    const host = host_of(context);

    std.debug.assert(file.len > 0);

    const module = std.mem.endsWith(u8, file, ".wasm");

    if (!module or !files_module.valid_upload(file)) {
        return error.Invalid;
    }

    return host.files.receive(file, offset, bytes, last) catch |err| switch (err) {
        error.OutOfOrder => error.Conflict,
        error.FileNotFound => error.Conflict,
        else => error.Unavailable,
    };
}

pub fn consume(context: *anyopaque, file: []const u8) void {
    const host = host_of(context);

    std.debug.assert(file.len > 0);

    if (files_module.valid_upload(file)) {
        host.files.remove_upload(file);
    }
}

pub fn stage(
    context: *anyopaque,
    arena: std.mem.Allocator,
    file: []const u8,
    anywhere: bool,
) sdk.Error!sdk.sandboxed_plugins.Staged {
    const host = host_of(context);

    std.debug.assert(file.len > 0);

    if (!anywhere and !files_module.valid_upload(file)) {
        return error.Invalid;
    }

    const path = if (anywhere) file else std.fmt.allocPrint(arena, "{s}/{s}", .{
        files_module.uploads_dir,
        file,
    }) catch return error.OutOfMemory;
    const bytes = host.files.read_any(host.gpa, path, anywhere) catch return error.NotFound;
    defer host.gpa.free(bytes);

    const plugin_manifest = @import("../../sdk/plugin/manifest.zig");
    const manifest = (wasm.section.find(bytes, plugin_manifest.section_name) catch {
        return error.Invalid;
    }) orelse return error.Invalid;

    const source = (wasm.section.find(bytes, plugin_manifest.source_section_name) catch {
        return error.Invalid;
    }) orelse "";

    try check_loads(host, bytes);

    var hash: [hash_len]u8 = undefined;

    host.files.store(bytes, &hash) catch return error.Unavailable;

    return .{
        .hash = arena.dupe(u8, &hash) catch return error.OutOfMemory,
        .manifest = arena.dupe(u8, manifest) catch return error.OutOfMemory,
        .source = arena.dupe(u8, source) catch return error.OutOfMemory,
    };
}

/// Whether the sandbox loads the module: valid, and importing only what the host gives.
fn check_loads(host: *Host, bytes: []const u8) sdk.Error!void {
    std.debug.assert(bytes.len > 0);

    const copy = host.gpa.dupe(u8, bytes) catch return error.OutOfMemory;
    defer host.gpa.free(copy);

    var problem: wasm.Problem = .{};
    var module = wasm.Module.load(&host.runtime, copy, &problem) catch {
        std.log.warn("plugins: the module does not load: {s}", .{problem.text()});
        return error.Invalid;
    };

    module.unload();
}
