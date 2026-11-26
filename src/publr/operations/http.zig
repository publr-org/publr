//! Requests a plugin sends out from queued work, its secrets filled in as they leave:
//! `ctx.call(publr.operations.http.Fetch, .{ .url = "https://api.example.com/quote" })`, and
//! an answer read as it arrives with `http.stream`.
const operation = @import("../operation.zig");

/// A request read piece by piece, as it arrives: `http.stream` and `http.read`.
pub const stream = @import("http/stream.zig");

/// Headers one request sends, at most.
pub const headers_max: u32 = 16;
/// What a plugin may send: a conversation with its pictures fits.
pub const body_bytes_max: u32 = 8 << 20;
/// What an answer may be.
pub const answer_bytes_max: u32 = 1 << 20;
/// Parts in one form, at most.
pub const form_parts_max: u32 = 16;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// HTTP Basic credentials: `Authorization: Basic base64(user:password)`, made after their
/// secrets are filled in.
pub const Basic = struct {
    user: []const u8,
    password: []const u8,
};

/// One part of a form upload (`multipart/form-data`): a file goes as base64, which JSON can
/// carry, and leaves as its bytes. A plugin never encodes files itself.
pub const FormPart = struct {
    name: []const u8,
    /// The text, or a file's bytes as base64 when `file_name` is set.
    value: []const u8 = "",
    /// Set for a file: the name it is uploaded under.
    file_name: []const u8 = "",
    /// A file's media type; `application/octet-stream` when empty.
    content_type: []const u8 = "",
};

pub const Fetch = struct {
    pub const name = "http.fetch";
    /// A plugin's alone: not listed among the commands people and agents run.
    pub const plugins_only = true;
    pub const description = "Send a request out, as the calling plugin";
    pub const details =
        \\Answers the status and the body (up to 1 MiB). Refused outside queued work (a job, an
        \\`on` hook), and unless the caller is a plugin granted `http.fetch`, every hop's
        \\host is among the grant's domains (and, in production, resolves to no local or
        \\private address), and every `{secret:NAME}` it names is declared in the plugin's
        \\`.secrets` and has a value (else "<label> isn't set"). Logged under the call or
        \\run: method, host, path, status, time; never the query, headers or bodies.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        method: []const u8 = "GET",
        url: []const u8,
        headers: []const Header = &.{},
        body: []const u8 = "",
        /// A form upload (multipart/form-data) in place of `body`, files as base64; the
        /// `Content-Type` is set for it. No secret is filled in a form.
        form: []const FormPart = &.{},
        /// HTTP Basic credentials, encoded by core once their secrets are filled in.
        basic: ?Basic = null,
    };
    pub const Out = struct {
        status: u16,
        body: []const u8,
    };
    /// Another server's bytes, sent and answered as they are: never read here.
    pub const verbatim = .{"body"};
    pub const example: In = .{
        .url = "https://api.example.com/quote",
        .headers = &.{.{
            .name = "Authorization",
            .value = "Bearer {secret:STOCKS_API_KEY}",
        }},
    };
    pub const example_out: Out = .{
        .status = 200,
        .body = "{\"price\":12.5}",
    };
    pub const field_docs: operation.Docs(In) = .{
        .method = "GET, POST, PUT, PATCH or DELETE",
        .url = "https, or http to this machine in development; may hold {secret:NAME}",
        .headers = "Up to 16, as name and value; values may hold {secret:NAME}",
        .body = "Up to 8 MiB; may hold {secret:NAME}",
        .form = "Up to 16 parts in place of the body: name, value, and for a file " ++
            "file_name and content_type, its value base64",
        .basic = "HTTP Basic `user` and `password`, each may hold {secret:NAME}: sent as " ++
            "`Authorization: Basic`, encoded after the secrets are filled in",
    };
};
