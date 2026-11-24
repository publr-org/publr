# CLI: `mail`

Email a plugin hands to a mail server over SMTP. `mail send` is a plugin's alone, granted
as `mail.send` (high tier), and only from queued work (a job, an `on` hook): to the server
it names, over TLS after STARTTLS (`--security starttls`, port 587) or from the start
(`tls`, port 465), the server's certificate checked against the system's; signed in with
AUTH PLAIN or LOGIN when it gives a user. `none` (no TLS) only in development. In
production local and private addresses and the server itself are refused, checked where
the name resolves and connected to the checked address, and so is every email on a host
that sends its traffic out through a proxy (`PUBLR_EGRESS`). `{secret:NAME}` in the user or
the password is filled in as it leaves, when the plugin declares it in `.secrets` (else
`SecretNotDeclared`) and it has a value (else "<label> isn't set", `SecretMissing`).
Each email is logged under the run that sent it (server, port, recipients' count, the
answer, time), never the message or the credentials.
Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `mail send --host <name> --from <address> --to <list> --message <text> [--port] [--security] [--user] [--password]` | Hand an email to an SMTP server, as the calling plugin |

The message is the email as written: headers (From, To, Subject, Date, Message-ID, MIME),
a blank line, the body, up to 8 MiB. Core ends its lines in CRLF and doubles a leading dot;
it writes no header of its own. Up to 50 recipients. It answers `sent` and `reply`: the
server's answer to the message (`250 2.0.0 Ok: queued as 4F3A`), or why it was not sent in
words (what the server refused with, TLS failing, no answer in 30 seconds). A messaging
provider turns `sent: false` into a failed run, which the queue tries again.
