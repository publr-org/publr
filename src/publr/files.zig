//! `ctx.make_file(type, filename)`: a file the plugin makes (an invoice's PDF, a label, a
//! feed), written in pieces as it is made and kept as a file of one of its own media types,
//! compiled in or installed alike. The plugin holds one piece at a time, never the file.
//!
//! ```zig
//! var file = try ctx.make_file("invoices.document", "invoice-FK-1.pdf");
//! try file.write(header);
//! try file.write(body);
//! const made = try file.done(); // made.id: the file's record, for a `reference` field
//! ```
const std = @import("std");
const made_operations = @import("operations/media/made.zig");
const Ctx = @import("ctx.zig").Ctx;
const file_key = @import("model/file_key.zig");

/// Whether `key` names a file of the media library (`2026/10/cat-a1b2c3.jpg`): up to four
/// `/`-separated segments of `[a-z0-9._-]`, none empty or hidden, at most `key_len_max`.
pub const valid_key = file_key.valid_key;
pub const key_len_max = file_key.key_len_max;

// Until `publr.Error` is the public set: an operation's errors, database ones among them.
pub const Error = @import("../sdk/operation.zig").Error;

/// What a made file is kept as.
pub const Made = struct {
    /// The file's record: what a `reference` field, a signed link (`{ "file": id }`) and a
    /// message's attachment name.
    id: []const u8,
    filename: []const u8,
    mime_type: []const u8,
    size: u64,
    /// Where staff open it: `/media/<key>`.
    key: []const u8,
    private: bool,
};

/// The file a plugin's `ctx` is making, either way it runs.
pub const Making = struct {
    const Self = @This();

    ctx: *Ctx,
    type_handle: []const u8,
    filename: []const u8,
    part: [part_len]u8,
    /// What was sent so far, in bytes.
    size: u64 = 0,
    /// One piece, filled before it is sent; from the call's arena, once per file.
    buffer: []u8 = &.{},
    filled: u32 = 0,

    pub fn begin(ctx: *Ctx, type_handle: []const u8, filename: []const u8) Self {
        std.debug.assert(type_handle.len > 0);
        std.debug.assert(filename.len > 0);

        var hash = std.hash.Fnv1a_64.init();

        hash.update(type_handle);
        hash.update(filename);

        const named = std.fmt.bytesToHex(std.mem.toBytes(hash.final()), .lower);
        const moment = std.fmt.bytesToHex(std.mem.toBytes(ctx.now().ms), .lower);
        var made: Self = .{
            .ctx = ctx,
            .type_handle = type_handle,
            .filename = filename,
            .part = undefined,
        };

        @memcpy(made.part[0..named.len], &named);
        @memcpy(made.part[named.len..], &moment);

        return made;
    }

    /// Adds `bytes` to the file: kept in one piece's buffer, sent each time it fills.
    pub fn write(self: *Self, bytes: []const u8) Error!void {
        std.debug.assert(self.filename.len > 0);
        std.debug.assert(bytes.len <= std.math.maxInt(u32));

        if (self.buffer.len == 0) {
            self.buffer = try self.ctx.alloc(u8, made_operations.part_bytes_max);
        }

        var rest = bytes;

        while (rest.len > 0) {
            const room = self.buffer.len - self.filled;
            const taken = @min(room, rest.len);

            @memcpy(self.buffer[self.filled..][0..taken], rest[0..taken]);
            self.filled += @intCast(taken);
            rest = rest[taken..];

            if (self.filled == self.buffer.len) {
                try self.flush();
            }
        }
    }

    fn flush(self: *Self) Error!void {
        std.debug.assert(self.filled <= self.buffer.len);

        if (self.filled == 0) {
            return;
        }

        try self.write_piece(self.buffer[0..self.filled]);
        self.filled = 0;
    }

    fn write_piece(self: *Self, piece: []const u8) Error!void {
        std.debug.assert(piece.len > 0);
        std.debug.assert(piece.len <= made_operations.part_bytes_max);

        const encoder = std.base64.standard.Encoder;
        const WritePart = made_operations.WritePart;
        // Outside the call's arena, given back once sent: the plugin holds one piece.
        const data = piece_allocator.alloc(u8, encoder.calcSize(piece.len)) catch {
            return error.OutOfMemory;
        };
        defer piece_allocator.free(data);

        _ = try self.ctx.call_named(WritePart.Out, WritePart.name, WritePart.In{
            .part = &self.part,
            .offset = self.size,
            .data = encoder.encode(data, piece),
        });
        self.size += piece.len;
    }

    /// Keeps what was written as a file of the plugin's media type: refused when nothing
    /// was, when its bytes are not what its name says, or past the plugin's file limit.
    pub fn done(self: *Self) Error!Made {
        std.debug.assert(self.filename.len > 0);

        try self.flush();

        if (self.size == 0) {
            return error.Invalid;
        }

        const item = try self.ctx.call(made_operations.Make, .{
            .part = &self.part,
            .filename = self.filename,
            .type = self.type_handle,
        });

        return .{
            .id = item.id,
            .filename = item.filename,
            .mime_type = item.mime_type,
            .size = item.size,
            .key = item.key,
            .private = item.private,
        };
    }
};

/// The part's name: the hash of the type and file name, then the moment, hex.
const part_len: u32 = 32;
/// The plugin's own heap, not the call's arena: a piece is given back as soon as it is sent.
const piece_allocator = if (@import("builtin").target.cpu.arch == .wasm32)
    @import("../sdk/plugin/guest_memory.zig").heap
else
    std.heap.page_allocator;
