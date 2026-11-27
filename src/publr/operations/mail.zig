//! Email a plugin hands to an SMTP server from queued work: `mail.send`.
const operation = @import("../operation.zig");

/// Recipients of one email, at most.
pub const recipients_max: u32 = 50;
/// What one email may be, headers and attachments included.
pub const message_bytes_max: u32 = 8 << 20;

/// How the connection is protected: TLS after STARTTLS (port 587), TLS from the start
/// (port 465), or none (development only).
pub const Security = enum { starttls, tls, none };

pub const namespace: operation.Namespace = .{
    .name = "mail",
    .label = "Outside mail",
    .area = .system,
    .summary = "Email a plugin hands to a mail server over SMTP",
    .details =
    \\From queued work alone (a job, an `on` hook), never a request someone waits on, a
    \\plugin granted `mail.send` hands an email to the SMTP server it names: over TLS after
    \\STARTTLS or from the start, the certificate checked, signed in when it gives a user,
    \\or in development with no TLS. In production local and private addresses and the
    \\server itself are refused, and so is a site whose host sends everything out through
    \\its proxy. `{secret:NAME}` in the user or the password is filled in as it leaves, when
    \\the plugin declares it in `.secrets`. Each email is logged (server, recipients'
    \\count, the server's answer). Plugins only: a messaging provider is how Publr's own
    \\emails reach SMTP.
    ,
};

pub const Send = struct {
    pub const name = "mail.send";
    /// A plugin's alone: not listed among the commands people and agents run.
    pub const plugins_only = true;
    /// Never written to the logs.
    pub const secret = .{"password"};
    pub const description = "Hand an email to an SMTP server, as the calling plugin";
    pub const details =
        \\Answers whether the server took it and its answer (`250 2.0.0 Ok: queued as 4F3A`),
        \\or why not in words: what the server said, TLS failing, no answer in 30 seconds.
        \\Refused outside queued work (a job, an `on` hook), unless the caller is a plugin
        \\granted `mail.send`, in production for a local or private address or `none`
        \\security, and when a `{secret:NAME}` it names is not declared in its `.secrets` or
        \\has no value ("<label> isn't set"). The message goes as written: headers, a blank
        \\line, the body; core ends its lines in CRLF and doubles a leading dot. Logged under
        \\the run: server, port, recipients' count, the answer, time; never the message or
        \\the credentials.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        host: []const u8,
        port: u16 = 587,
        security: Security = .starttls,
        user: []const u8 = "",
        password: []const u8 = "",
        from: []const u8,
        to: []const []const u8,
        message: []const u8,
    };
    pub const Out = struct {
        sent: bool,
        reply: []const u8,
    };
    pub const example: In = .{
        .host = "smtp.example.com",
        .user = "shop@example.com",
        .password = "{secret:SMTP_PASSWORD}",
        .from = "shop@example.com",
        .to = &.{"ada@example.com"},
        .message = "From: Shop <shop@example.com>\r\nTo: ada@example.com\r\n" ++
            "Subject: Your order\r\n\r\nThank you.\r\n",
    };
    pub const example_out: Out = .{
        .sent = true,
        .reply = "250 2.0.0 Ok: queued as 4F3A",
    };
    pub const field_docs: operation.Docs(In) = .{
        .host = "The SMTP server's name: smtp.example.com",
        .port = "587 for STARTTLS, 465 for TLS, 25 for none",
        .security = "starttls, tls, or none (development only)",
        .user = "Signs in when given; may hold {secret:NAME}",
        .password = "May hold {secret:NAME}",
        .from = "The envelope's sender: shop@example.com",
        .to = "The envelope's recipients, 1 to 50",
        .message = "The email as written (RFC 5322), up to 8 MiB",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .sent = "Whether the server took it",
        .reply = "The server's answer to the message, or why it was not sent",
    };
};
