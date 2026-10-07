//! Plugin modules on the data drive: `plugins/<sha256>.wasm` next to the database, named by
//! their content, so installing the same module twice writes nothing and a row names its file
//! by hash alone.
const std = @import("std");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");

pub const hash_len: u32 = 64;
/// Where an upload arrives before it is added: `plugins/incoming/`.
pub const uploads_dir = "incoming";

pub const Files = struct {
    dir: std.Io.Dir,
    io: std.Io,

    /// Opens (creating it when missing) the folder the modules live in.
    pub fn open(io: std.Io, path: []const u8) !Files {
        std.debug.assert(path.len > 0);
        std.debug.assert(path.len < 4096);

        const cwd = std.Io.Dir.cwd();

        try cwd.createDirPath(io, path);

        var dir = try cwd.openDir(io, path, .{ .iterate = true });
        errdefer dir.close(io);

        try dir.createDirPath(io, uploads_dir);

        return .{ .dir = dir, .io = io };
    }

    pub fn close(files: *Files) void {
        std.debug.assert(hash_len == 64);
        files.dir.close(files.io);
    }

    /// Reads a module, up to the size a plugin may have: from anywhere when `anywhere`, else
    /// from inside the plugins folder (an upload).
    pub fn read_any(
        files: *const Files,
        gpa: std.mem.Allocator,
        path: []const u8,
        anywhere: bool,
    ) ![]u8 {
        std.debug.assert(path.len > 0);
        std.debug.assert(sandboxed_plugin.bytes_max > 0);

        const dir = if (anywhere) std.Io.Dir.cwd() else files.dir;

        return dir.readFileAlloc(files.io, path, gpa, .limited(sandboxed_plugin.bytes_max));
    }

    /// Reads the stored module `hash`.
    pub fn read(files: *const Files, gpa: std.mem.Allocator, hash: []const u8) ![]u8 {
        std.debug.assert(hash.len == hash_len);
        std.debug.assert(valid_hash(hash));

        var name_buffer: [hash_len + 5]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s}.wasm", .{hash}) catch unreachable;

        return files.dir.readFileAlloc(files.io, name, gpa, .limited(sandboxed_plugin.bytes_max));
    }

    /// Stores `bytes` under their hash, once; answers the hash.
    pub fn store(files: *const Files, bytes: []const u8, hash_out: *[hash_len]u8) !void {
        std.debug.assert(bytes.len > 0);
        std.debug.assert(bytes.len <= sandboxed_plugin.bytes_max);

        hash_out.* = hash_of(bytes);

        var name_buffer: [hash_len + 5]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s}.wasm", .{hash_out}) catch unreachable;

        files.dir.access(files.io, name, .{}) catch {
            try files.dir.writeFile(files.io, .{ .sub_path = name, .data = bytes });
        };
    }

    /// Writes one piece of an upload at `offset` into `incoming/<name>.part`: the first piece
    /// starts it afresh, each next one must start where the last ended, and the last one
    /// moves it to `incoming/<name>`. Answers how many bytes the upload holds now.
    pub fn receive(
        files: *const Files,
        name: []const u8,
        offset: u64,
        bytes: []const u8,
        last: bool,
    ) !u64 {
        std.debug.assert(valid_upload(name));
        std.debug.assert(bytes.len <= sandboxed_plugin.bytes_max);

        var dir = try files.dir.openDir(files.io, uploads_dir, .{});
        defer dir.close(files.io);

        var part_buffer: [160]u8 = undefined;
        const part = try std.fmt.bufPrint(&part_buffer, "{s}.part", .{name});
        var file = if (offset == 0)
            try dir.createFile(files.io, part, .{ .truncate = true })
        else
            try dir.openFile(files.io, part, .{ .mode = .read_write });
        defer file.close(files.io);

        const size = (try file.stat(files.io)).size;

        if (size != offset or size + bytes.len > sandboxed_plugin.bytes_max) {
            return error.OutOfOrder;
        }

        try file.writePositionalAll(files.io, bytes, size);

        const received = size + bytes.len;

        if (last) {
            try dir.rename(part, dir, name, files.io);
        }

        return received;
    }

    /// Removes every stored module no row names: what a removal, an update or a cancelled
    /// update left behind, once it committed.
    pub fn sweep(files: *const Files, keep: []const []const u8) void {
        std.debug.assert(keep.len <= sandboxed_plugin.sandboxed_plugins_max * 2);

        var iterator = files.dir.iterate();
        var seen: u32 = 0;

        while (iterator.next(files.io) catch null) |entry| : (seen += 1) {
            if (seen == sandboxed_plugin.sandboxed_plugins_max * 4) {
                break;
            }

            const stem = std.mem.cutSuffix(u8, entry.name, ".wasm") orelse continue;

            if (entry.kind == .file and valid_hash(stem) and !listed(keep, stem)) {
                files.remove(stem);
            }
        }
    }

    /// Removes `incoming/<name>`; one already gone is fine.
    pub fn remove_upload(files: *const Files, name: []const u8) void {
        std.debug.assert(valid_upload(name));

        var path_buffer: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ uploads_dir, name }) catch return;

        files.dir.deleteFile(files.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("plugins: could not remove the upload {s}: {t}", .{ name, err }),
        };
    }

    /// Removes the stored module `hash`; one already gone is fine.
    pub fn remove(files: *const Files, hash: []const u8) void {
        std.debug.assert(hash.len == hash_len);
        std.debug.assert(valid_hash(hash));

        var name_buffer: [hash_len + 5]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "{s}.wasm", .{hash}) catch unreachable;

        files.dir.deleteFile(files.io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("plugins: could not remove {s}: {t}", .{ name, err }),
        };
    }
};

/// An upload's name: letters, digits, dots, dashes and underscores, never a path.
pub fn valid_upload(name: []const u8) bool {
    std.debug.assert(uploads_dir.len > 0);

    if (name.len == 0 or name.len > 128 or name[0] == '.') {
        return false;
    }

    for (name) |char| {
        const ok = std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or char == '_';

        if (!ok) {
            return false;
        }
    }

    return true;
}

fn less_than(_: void, left: []const u8, right: []const u8) bool {
    std.debug.assert(left.len > 0);
    std.debug.assert(right.len > 0);

    return std.mem.lessThan(u8, left, right);
}

fn listed(keep: []const []const u8, hash: []const u8) bool {
    std.debug.assert(hash.len == hash_len);

    for (keep) |kept| {
        if (std.mem.eql(u8, kept, hash)) {
            return true;
        }
    }

    return false;
}

pub fn hash_of(bytes: []const u8) [hash_len]u8 {
    std.debug.assert(bytes.len > 0);
    std.debug.assert(hash_len == 64);

    var digest: [32]u8 = undefined;

    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});

    return std.fmt.bytesToHex(digest, .lower);
}

pub fn valid_hash(hash: []const u8) bool {
    std.debug.assert(hash_len == 64);

    if (hash.len != hash_len) {
        return false;
    }

    for (hash) |char| {
        if (!std.ascii.isDigit(char) and !(char >= 'a' and char <= 'f')) {
            return false;
        }
    }

    return true;
}

test "hashes are lowercase hex of the content" {
    const hash = hash_of("abc");

    try std.testing.expect(valid_hash(&hash));
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &hash,
    );
    try std.testing.expect(!valid_hash("ABC"));
    try std.testing.expect(!valid_hash("../../../../etc/passwd" ++ "x" ** 42));
    try std.testing.expect(valid_upload("greeter-0.1.0.wasm"));
    try std.testing.expect(!valid_upload("../greeter.wasm"));
    try std.testing.expect(!valid_upload(".hidden"));
}
