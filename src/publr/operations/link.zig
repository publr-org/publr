//! Signed links: a plugin signs what a link may do (its intent, the record it is for, until
//! when) so a person opens it without signing in: unsubscribe, a cart restored, an invoice,
//! a withdrawal. The signature is keyed by a secret the site keeps and no plugin holds;
//! `link.revoke_all` draws a new one, and every link signed before stops working. An
//! intent is its plugin's own (`<plugin>.<intent>`): no plugin signs or reads another's.
//! A link `/_links/<token>` runs the plugin's operation the intent names, as the plugin,
//! given the subject.
const operation = @import("../operation.zig");

/// The longest subject a link is signed for.
pub const subject_len_max: u32 = 256;
/// The longest intent, the plugin's name in front.
pub const intent_len_max: u32 = 96;
/// The longest token read back.
pub const token_len_max: u32 = 1024;

pub const namespace: operation.Namespace = .{
    .name = "link",
    .label = "Signed links",
    .area = .system,
    .summary = "Links a person opens without signing in, signed for one purpose",
    .details =
    \\A plugin signs a link for one purpose (its intent: `unsubscribe`), one subject (a
    \\subscriber's id) and a time it stops working; the site checks it when it is opened.
    \\Only the plugin that signed a link reads it. `link revoke_all` stops every link signed
    \\so far. A link opened at `/_links/<token>` runs the operation its intent names.
    ,
};

pub const Sign = struct {
    pub const name = "link.sign";
    pub const plugins_only = true;
    pub const description = "Sign a link for one purpose and one subject, until a time";
    pub const details =
        \\Plugins only. The intent is the plugin's own (`unsubscribe` is kept as
        \\`<plugin>.unsubscribe`), so only it reads the token back (`link.verify`) and a
        \\link to `/_links/<token>` runs its operation of that name. `expires_at` of 0 keeps
        \\it working until `link revoke_all`.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        intent: []const u8,
        subject: []const u8,
        expires_at: i64 = 0,
    };
    pub const Out = struct {
        token: []const u8,
        path: []const u8,
    };
    pub const example: In = .{
        .intent = "unsubscribe",
        .subject = "9b1e7c3d5a2f4e6b8d0c1a3f",
    };
    pub const example_out: Out = .{
        .token = "eyJpIjoibmV3c2xldHRlci51bnN1YnNjcmliZSJ9.Qm9i",
        .path = "/_links/eyJpIjoibmV3c2xldHRlci51bnN1YnNjcmliZSJ9.Qm9i",
    };
    pub const field_docs: operation.Docs(In) = .{
        .intent = "What the link may do, the plugin's own word: `unsubscribe`",
        .subject = "What it is for: a record's id, an email",
        .expires_at = "When it stops working (ms since 1970); 0 never",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .token = "The signed token",
        .path = "The link opening it, from the site's root",
    };
};

pub const Verify = struct {
    pub const name = "link.verify";
    pub const plugins_only = true;
    /// Never written to the logs.
    pub const secret = .{"token"};
    pub const description = "Read a signed link's subject back, when it is good for the intent";
    pub const details =
        \\Plugins only, for their own intents. Answers the subject the link was signed for;
        \\not found when the token is not one the site signed for this intent and plugin,
        \\has stopped working, or was revoked.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        intent: []const u8,
        token: []const u8,
    };
    pub const Out = struct {
        subject: []const u8,
        expires_at: i64,
    };
    pub const example: In = .{
        .intent = "unsubscribe",
        .token = "eyJpIjoibmV3c2xldHRlci51bnN1YnNjcmliZSJ9.Qm9i",
    };
    pub const example_out: Out = .{
        .subject = "9b1e7c3d5a2f4e6b8d0c1a3f",
        .expires_at = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .intent = "The plugin's word it was signed for",
        .token = "The token from the link",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .subject = "What it was signed for",
        .expires_at = "When it stops working; 0 never",
    };
};

pub const RevokeAll = struct {
    pub const name = "link.revoke_all";
    pub const description = "Stop every signed link the site gave out so far";
    pub const details =
        \\Administrators only. The site draws a new key: every link signed before (an
        \\unsubscribe, a cart, an invoice) stops working; links signed from now on work.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {};
    pub const Out = struct {};
    pub const example: In = .{};
    pub const example_out: Out = .{};
};
