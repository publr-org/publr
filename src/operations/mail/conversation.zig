//! An SMTP conversation on a connection already made: the greeting, EHLO, STARTTLS when
//! asked, the sign-in, the envelope and the message, each answer checked; a refusal keeps
//! what the server said.
const std = @import("std");
const smtp = @import("smtp.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const TlsClient = std.crypto.tls.Client;
const Failure = smtp.Failure;
const Request = smtp.Request;
const Result = smtp.Result;

/// A server's answer, all its lines, at most.
const reply_bytes_max: u32 = 4096;
/// One line of a server's answer, at most (RFC 5321 says 512).
const line_bytes_max: u32 = 1024;
const lines_max: u32 = 64;

pub const Session = struct {
    io: std.Io,
    arena: std.mem.Allocator,
    host: []const u8,
    plain_in: *Reader,
    plain_out: *Writer,
    in: *Reader,
    out: *Writer,
    tls_read: []u8,
    tls_write: []u8,
    tls_client: ?TlsClient = null,
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,
    result: *Result,
    /// What the last answer said, every line.
    reply_buffer: [reply_bytes_max]u8 = undefined,

    const Stop = error{Stop};

    fn fail(session: *Session, failure: Failure) Stop {
        session.result.failed = failure;
        return error.Stop;
    }

    /// Sends one command line.
    fn command(session: *Session, comptime format: []const u8, args: anytype) Stop!void {
        session.out.print(format ++ "\r\n", args) catch {
            return session.fail(.unreachable_server);
        };
        try session.flush();
    }

    fn flush(session: *Session) Stop!void {
        session.out.flush() catch return session.fail(.unreachable_server);

        if (session.tls_client != null) {
            session.plain_out.flush() catch return session.fail(.unreachable_server);
        }
    }

    /// The server's answer, all its lines: its code, and the text kept in
    /// `reply_buffer`.
    fn reply(session: *Session) Stop!Reply {
        var length: usize = 0;
        var code: u16 = 0;

        for (0..lines_max) |_| {
            const line = session.in.takeDelimiterInclusive('\n') catch {
                return session.fail(.unreachable_server);
            };
            const text = std.mem.trimEnd(u8, line, "\r\n");

            if (text.len < 3 or text.len > line_bytes_max) {
                return session.fail(.unreachable_server);
            }

            code = std.fmt.parseInt(u16, text[0..3], 10) catch {
                return session.fail(.unreachable_server);
            };

            const room = session.reply_buffer.len - length;
            const kept = @min(room, text.len + 1);

            if (kept > 0) {
                @memcpy(session.reply_buffer[length..][0 .. kept - 1], text[0 .. kept - 1]);
                session.reply_buffer[length + kept - 1] = '\n';
                length += kept;
            }

            const more = text.len > 3 and text[3] == '-';

            if (!more) {
                return .{
                    .code = code,
                    .text = std.mem.trimEnd(u8, session.reply_buffer[0..length], "\n"),
                };
            }
        }

        return session.fail(.unreachable_server);
    }

    /// The answer, which must be `wanted` (its first digit when below 10); else the
    /// conversation stops with what the server said.
    fn expect(session: *Session, wanted: u16) Stop!Reply {
        std.debug.assert(wanted > 0 and wanted < 600);

        const answer = try session.reply();
        const fits = if (wanted < 10) answer.code / 100 == wanted else answer.code == wanted;

        if (!fits) {
            session.result.said = session.arena.dupe(u8, answer.text) catch "";
            return session.fail(.refused);
        }

        return answer;
    }

    /// TLS over the connection from here on: the certificate must be the host's, signed by
    /// one the system trusts.
    fn secure(session: *Session) Stop!void {
        std.debug.assert(session.tls_client == null);

        const now = std.Io.Clock.real.now(session.io);

        session.ca_bundle.rescan(session.arena, session.io, now) catch |err| {
            session.result.said = @errorName(err);
            return session.fail(.tls);
        };

        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;

        session.io.random(&entropy);
        session.tls_client = TlsClient.init(session.plain_in, session.plain_out, .{
            .host = .{
                .explicit = session.host,
            },
            .ca = .{
                .bundle = .{
                    .gpa = session.arena,
                    .io = session.io,
                    .lock = &session.ca_lock,
                    .bundle = &session.ca_bundle,
                },
            },
            .read_buffer = session.tls_read,
            .write_buffer = session.tls_write,
            .entropy = &entropy,
            .realtime_now = now,
        }) catch |err| {
            session.result.said = @errorName(err);
            return session.fail(.tls);
        };

        session.in = &session.tls_client.?.reader;
        session.out = &session.tls_client.?.writer;
    }

    /// Ends TLS politely; a connection already broken has nothing left to say.
    pub fn close(session: *Session) void {
        std.debug.assert(session.in == session.plain_in or session.tls_client != null);

        if (session.tls_client) |*client| {
            client.end() catch return;
        }

        session.plain_out.flush() catch return;
    }
};

const Reply = struct {
    code: u16,
    text: []const u8,
};

pub fn converse(session: *Session, request: Request) Session.Stop!void {
    std.debug.assert(request.to.len > 0);

    if (request.security == .tls) {
        try session.secure();
    }

    _ = try session.expect(220);
    try session.command("EHLO {s}", .{request.greeting});

    var offered = try session.expect(250);

    if (request.security == .starttls) {
        if (!capable(offered.text, "STARTTLS")) {
            return session.fail(.no_starttls);
        }

        try session.command("STARTTLS", .{});
        _ = try session.expect(220);
        try session.secure();
        try session.command("EHLO {s}", .{request.greeting});
        offered = try session.expect(250);
    }

    if (request.user.len > 0) {
        try sign_in(session, request, offered.text);
    }

    try session.command("MAIL FROM:<{s}>", .{request.from});
    _ = try session.expect(250);

    for (request.to) |recipient| {
        try session.command("RCPT TO:<{s}>", .{recipient});
        _ = try session.expect(2);
    }

    try session.command("DATA", .{});
    _ = try session.expect(354);
    try message_written(session, request.message);

    const taken = try session.expect(250);

    session.result.said = session.arena.dupe(u8, taken.text) catch "";
    session.command("QUIT", .{}) catch return;
    _ = session.reply() catch return;
}

/// AUTH PLAIN when the server offers it, else LOGIN.
fn sign_in(session: *Session, request: Request, offered: []const u8) Session.Stop!void {
    std.debug.assert(request.user.len > 0);

    const encoder = std.base64.standard.Encoder;
    const methods = auth_methods(offered);

    if (has_word(methods, "PLAIN")) {
        const plain = std.fmt.allocPrint(session.arena, "\x00{s}\x00{s}", .{
            request.user,
            request.password,
        }) catch return session.fail(.out_of_memory);
        const encoded = session.arena.alloc(u8, encoder.calcSize(plain.len)) catch {
            return session.fail(.out_of_memory);
        };

        try session.command("AUTH PLAIN {s}", .{encoder.encode(encoded, plain)});
        _ = try session.expect(235);
        return;
    }

    if (!has_word(methods, "LOGIN")) {
        return session.fail(.no_sign_in);
    }

    try session.command("AUTH LOGIN", .{});
    _ = try session.expect(334);

    for ([_][]const u8{ request.user, request.password }, 0..) |value, index| {
        const encoded = session.arena.alloc(u8, encoder.calcSize(value.len)) catch {
            return session.fail(.out_of_memory);
        };

        try session.command("{s}", .{encoder.encode(encoded, value)});
        _ = try session.expect(if (index == 0) 334 else 235);
    }
}

/// The message after DATA: every line ending in CRLF, a line starting with a dot given a
/// second one, then the lone dot that ends it.
fn message_written(session: *Session, message: []const u8) Session.Stop!void {
    var lines = std.mem.splitScalar(u8, message, '\n');

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");

        if (lines.peek() == null and line.len == 0) {
            break;
        }

        if (line.len > 0 and line[0] == '.') {
            session.out.writeByte('.') catch return session.fail(.unreachable_server);
        }

        session.out.writeAll(line) catch return session.fail(.unreachable_server);
        session.out.writeAll("\r\n") catch return session.fail(.unreachable_server);
    }

    session.out.writeAll(".\r\n") catch return session.fail(.unreachable_server);
    try session.flush();
}

/// Whether EHLO's answer lists `extension` (each line after the code: `250-STARTTLS`).
fn capable(offered: []const u8, extension: []const u8) bool {
    std.debug.assert(extension.len > 0);

    var lines = std.mem.splitScalar(u8, offered, '\n');

    while (lines.next()) |line| {
        if (line.len < 4) {
            continue;
        }

        var words = std.mem.tokenizeScalar(u8, line[4..], ' ');
        const first = words.next() orelse continue;

        if (std.ascii.eqlIgnoreCase(first, extension)) {
            return true;
        }
    }

    return false;
}

/// The words after AUTH in EHLO's answer: `PLAIN LOGIN`.
fn auth_methods(offered: []const u8) []const u8 {
    std.debug.assert(offered.len <= reply_bytes_max);

    var lines = std.mem.splitScalar(u8, offered, '\n');

    while (lines.next()) |line| {
        if (line.len < 9) {
            continue;
        }

        const rest = line[4..];

        if (std.ascii.startsWithIgnoreCase(rest, "AUTH ") or
            std.ascii.startsWithIgnoreCase(rest, "AUTH="))
        {
            return rest[5..];
        }
    }

    return "";
}

fn has_word(words_text: []const u8, word: []const u8) bool {
    std.debug.assert(word.len > 0);

    var words = std.mem.tokenizeScalar(u8, words_text, ' ');

    while (words.next()) |each| {
        if (std.ascii.eqlIgnoreCase(each, word)) {
            return true;
        }
    }

    return false;
}

/// Whether `address` can stand in an envelope: an address with an @, no spaces, angle
/// brackets or line breaks.
pub fn envelope_address(address: []const u8) bool {
    std.debug.assert(address.len <= 64 << 20);

    if (address.len < 3 or address.len > 254) {
        return false;
    }

    const at = std.mem.lastIndexOfScalar(u8, address, '@') orelse return false;

    if (at == 0 or at + 1 == address.len) {
        return false;
    }

    for (address) |byte| {
        if (byte <= ' ' or byte == '<' or byte == '>' or byte == 0x7f) {
            return false;
        }
    }

    return true;
}

test "EHLO's answer is read for STARTTLS and the sign-in methods" {
    const offered = "250-mail.example.com\n250-STARTTLS\n250-AUTH LOGIN PLAIN\n250 8BITMIME";

    try std.testing.expect(capable(offered, "STARTTLS"));
    try std.testing.expect(!capable(offered, "SMTPUTF8"));
    try std.testing.expect(has_word(auth_methods(offered), "PLAIN"));
    try std.testing.expect(has_word(auth_methods(offered), "login"));
    try std.testing.expect(!has_word(auth_methods("250 OK"), "PLAIN"));
}

test "an envelope address has an @ and nothing a command could be split on" {
    try std.testing.expect(envelope_address("ada@example.com"));
    try std.testing.expect(!envelope_address("ada@example.com>\r\nRCPT TO:<x@y.z"));
    try std.testing.expect(!envelope_address("ada example.com"));
    try std.testing.expect(!envelope_address("@example.com"));
}
