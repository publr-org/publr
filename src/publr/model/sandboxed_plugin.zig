//! What a plugin declares of webhooks, jobs, icons and its limits, as `publr.plugin.define`
//! and `publr.webhook.define` take it.

/// A permission a plugin asks for, by the key the administrator sees, with its own reason,
/// the content types or taxonomies it names and its flags.
pub const Ask = struct {
    key: []const u8,
    reason: []const u8,
    records: []const []const u8 = &.{},
    taxonomies: []const []const u8 = &.{},
    /// `http.fetch`'s: where it may send.
    domains: []const []const u8 = &.{},
    /// `ledger.read`'s: whose accounts it reads.
    plugins: []const []const u8 = &.{},
    drafts: bool = false,
    private: bool = false,
    internal: bool = false,
    publish: bool = false,
};

/// How a webhook's sender signs.
pub const Signature = union(enum) {
    /// An HMAC-SHA256 of the body in a header (`X-Hub-Signature-256: sha256=<hex>`).
    hmac: struct {
        header: []const u8,
        prefix: []const u8 = "",
        encoding: Encoding = .hex,
    },
    /// The timestamped HMAC payment providers send: `t=<seconds>,v1=<hex>` over
    /// `<seconds>.<body>`, refused when the time is over five minutes off.
    timestamped: struct {
        header: []const u8,
    },
    /// The secret itself, in a header.
    token: struct {
        header: []const u8,
    },
    /// Signed in a way only the plugin reads (a digest of fields in the body, the gateway
    /// asked back): core takes the delivery as it comes, and the run confirms it with
    /// `secret.digest` (any of the plugin's secrets) or the gateway's own answer before
    /// anything acts. Never dropped
    /// as a repeat: a forged copy must not stand in for the real one.
    verify: struct {},
};

pub const Encoding = enum { hex, base64 };

/// How a webhook's body is read: JSON, a form, or the bytes as they came.
pub const Body = enum { json, form, raw };

/// Where a delivery's own id is, so a repeat is dropped: a header, or a top-level field.
pub const DeliveryId = union(enum) {
    header: []const u8,
    field: []const u8,
};

/// A record's datetime field a job follows: it runs once per value, `offset_ms` from it.
pub const Due = struct {
    /// The record's type, by its full name.
    type: []const u8,
    field: []const u8,
    /// Negative for `.before`.
    offset_ms: i64,
    /// The record is a plugin's internal record (`subscriptions.subscription`): its moment
    /// is read from its document.
    internal: bool = false,
    /// It comes back every year (a birthday, a card's expiry): the run follows its next
    /// return, and once run, the one after.
    yearly: bool = false,
};

/// More than the defaults, asked for with a reason; each raised limit waits for approval.
pub const Limits = struct {
    cpu_ms: ?u32 = null,
    memory_mib: ?u32 = null,
    calls: ?u32 = null,
    output_kib: ?u32 = null,
    /// The largest file it makes (`ctx.make_file`), in MiB.
    file_mib: ?u32 = null,
    reason: []const u8 = "",
};

/// An icon a plugin brings, named `<plugin>.<name>`: a 24×24 drawing, sanitized as any SVG
/// before a page shows it.
pub const PluginIcon = struct {
    name: []const u8,
    svg: []const u8,
};
