const std = @import("std");

pub const Upload = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    path: []const u8,
    /// How much is read and sent between two progress reports.
    piece_bytes: u32,
    /// Where the progress goes: `Uploading... 40%`.
    out: *std.Io.Writer,
};

pub const Reply = struct {
    status: std.http.Status,
    body: []const u8,
};

const answer_bytes_max: u32 = 64 << 10;

/// The file at `path` posted as the body, read and sent a piece at a time with its length
/// declared, so a site of any size never sits in memory; the answer.
pub fn send(upload: Upload) !Reply {
    std.debug.assert(upload.url.len > 0);
    std.debug.assert(upload.piece_bytes > 0);

    var file = try std.Io.Dir.cwd().openFile(upload.io, upload.path, .{});
    defer file.close(upload.io);

    var file_buffer: [64 << 10]u8 = undefined;
    var reader = file.reader(upload.io, &file_buffer);
    const size = try reader.getSize();
    var client: std.http.Client = .{
        .allocator = upload.arena,
        .io = upload.io,
    };
    defer client.deinit();

    const bearer = try std.fmt.allocPrint(upload.arena, "Bearer {s}", .{upload.token});
    var request = try client.request(.POST, try std.Uri.parse(upload.url), .{
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{
            .content_type = .{
                .override = "application/gzip",
            },
        },
        .extra_headers = &.{.{
            .name = "Authorization",
            .value = bearer,
        }},
    });
    defer request.deinit();

    request.transfer_encoding = .{
        .content_length = size,
    };

    var body_buffer: [64 << 10]u8 = undefined;
    var body = try request.sendBodyUnflushed(&body_buffer);

    try send_pieces(upload, &reader.interface, &body.writer, size);
    try body.end();
    try request.connection.?.flush();

    return receive(upload, &request);
}

fn send_pieces(upload: Upload, from: *std.Io.Reader, to: *std.Io.Writer, size: u64) !void {
    std.debug.assert(upload.piece_bytes > 0);
    std.debug.assert(size > 0);

    var sent: u64 = 0;

    while (sent < size) {
        const piece = @min(size - sent, upload.piece_bytes);

        try from.streamExact64(to, piece);
        sent += piece;
        try upload.out.print("\rUploading... {d}%", .{sent * 100 / size});
        try upload.out.flush();
    }

    std.debug.assert(sent == size);

    try upload.out.print("\n", .{});
}

fn receive(upload: Upload, request: *std.http.Client.Request) !Reply {
    std.debug.assert(upload.url.len > 0);
    std.debug.assert(answer_bytes_max > 0);

    var response = try request.receiveHead(&.{});
    const status = response.head.status;
    var transfer: [64]u8 = undefined;
    const reader = response.reader(&transfer);
    const remaining = reader.allocRemaining(upload.arena, .limited(answer_bytes_max));
    const body = remaining catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => return err,
    };

    return .{
        .status = status,
        .body = body,
    };
}
