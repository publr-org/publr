# CLI: `http`

Requests a plugin sends out. `http fetch` is a plugin's alone, granted as `http.fetch`
(high tier): to the domains it declares in `allowed_domains`, over https, or plain http to
this machine. `{secret:NAME}` in the address, a header or the body is filled in with the
secret's value as the request leaves, when the plugin was granted `secret.NAME`; a value the
answer echoes comes back as `{secret:NAME}`. Sends up to 8 MiB; answers the status and up to
1 MiB of the body.
Back to the [CLI reference](../cli.md).

| Command | What |
|---|---|
| `http fetch --url <url> [--method] [--headers] [--body] [--form]` | Send a request out, as the calling plugin |

`--form`, in place of a body, is a form upload of up to 16 parts (`name`, `value`, and for
a file `file_name` and `content_type`, its value base64): core writes it as
`multipart/form-data` with the file's bytes and sets the `Content-Type`. No secret is
filled in a form.

`http.stream` sends a request as `http.fetch` does, under the same grant and domains, and
answers once the response's head is in: its status and a `handle`. `http.read --handle`
then hands over the body as it arrives, a piece at a time (up to 16 KiB, waiting until
some has come), `done` at its end. A model provider reads a reply this way, so it can be
shown as it is written. Only in an agent's process; a status other than 200 answers with
the body at once.

