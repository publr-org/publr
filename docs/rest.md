# REST API

Publr speaks JSON over HTTP under `/api/`. Start the server with `publr serve`
(see [Serving](cli.md#serving)), then call it from anything that can make an
HTTP request. Signed-in browsers use a cookie; the CLI and scripts do not need
one.

## Conventions

- Requests and responses are JSON (`Content-Type: application/json`).
- Errors are JSON too: `{ "error": "<name>" }` with a matching status
  (`401` wrong credentials, `403` denied or cross-origin, `404` not found, `409` conflict,
  `422` invalid input, `429` too many attempts, `503` a service it needs is down: try
  again). A failure a plugin declares answers with its own status and name, and a
  `message`: `{ "error": "Unverified", "message": "…" }`.
- Requests that change something must be same-origin (`Origin` or `Referer`
  matches `Host`) and, when a session cookie is present, carry the session's
  CSRF token in `X-Csrf-Token` (you get it from sign-in or `/api/auth/session`).
- Anything not listed answers `404`.

## Every operation, one rule

Every operation is reachable at `/api/<namespace>/<verb>`, the same names the
CLI uses (`publr --help` lists them, `publr <namespace> <verb> --help` documents
each with its input and output). Read operations answer `GET` with the input as
query parameters; write operations take `POST` with the input as a JSON body.
The response body is the operation's output as JSON, exactly what the CLI
prints. Signed-in requests carry the session cookie; writes also carry
`X-Csrf-Token`.

```
GET  /api/record/list?type=post&status=published&limit=20
POST /api/record/create        {"type":"post","document":"{\"title\":\"Hello\"}"}
POST /api/record/transition    {"id":"…","to":"published"}
GET  /api/content_type/get?type=post
GET  /api/record/referrers?id=…
GET  /api/term/tree?taxonomy=topics
POST /api/term/create          {"taxonomy":"topics","document":"{\"name\":\"Engineering\"}","parent":"…"}
```

Plugins' operations appear the same way (`POST /api/<namespace>/<verb>`); what an app
calls has the namespace `app.<feature>` (`POST /api/app.newsletter/subscribe`).
Unknown operations answer `404 { "error": "unknown_operation" }`; `GET` on a
write operation answers `405`.

## The apps

Everything outside `/api/`, `/admin/` and `/auth/` belongs to the app mounted where it
was asked (see [Apps](apps.md)): its subdomain, else the longest path mount. Under an
app's mount are its routes, `<mount>/_islands/<key>` and `<mount>/_islands/?keys=a,b` for
fragments, and `<mount>/_app/<path>` for its stylesheet (`app.css`) and its assets. A built
page answers with an `ETag`, a rendered one with `no-store`; `X-Publr-Served` says which
(`file`, `memory`, `render`). With no app there, `/` opens the admin.

## Health

| Route | What |
|---|---|
| `GET /api/health` | `{ "version", "echo", "caller" }`; `caller` is who you are (`anonymous`, or a user id) |

## The CLI next to the server

| Route | What |
|---|---|
| `POST /_publr/apps/load` | from `publr apps load`, with the same key: the apps read from their folder again and swapped in; answers `{ "loaded" }` or `{ "error" }` |
| `POST /_publr/cli` | body `{ "args", "password" }`: a command the CLI sends the server running for its database, run as the CLI would run it; answers `{ "code", "out", "err" }`. Only with the key this run of `serve` wrote beside the database (`X-Publr-Operator`), else `403`; see [CLI](cli.md#while-a-server-runs) |

## Authentication

| Route | What |
|---|---|
| `POST /api/auth/sign-in` | body `{ "email", "password" }`; sets the `publr_session` cookie (for the whole domain when an app answers on a subdomain); returns `{ "user_id", "expires_at", "csrf" }`. An app's own sign-in form posts here |
| `POST /api/auth/sign-out` | revokes the cookie's session; needs `X-Csrf-Token`; returns `{ "signed_out" }` |
| `GET /api/auth/session` | `{ "authenticated", "user_id", "roles", "csrf" }` for the cookie |
| `GET /auth/<provider>` | starts signing in with a provider a plugin declares (`?next=` a path on this site to land on): keeps `state` and a PKCE verifier in the `publr_auth` cookie for ten minutes and redirects to the provider; `404` for a provider not offered |
| `GET /auth/<provider>/callback` | where the provider sends the browser back: checks `state` against the cookie, asks the plugin who the code stands for, signs that account in (`identity.sign_in`) or links the identity to the signed-in account (`identity.link`), and redirects to `next`; anything refused lands on `/admin/login?identity=refused` |
| `POST /api/auth/set-password` | body `{ "token", "password" }` from a set-password link; activates the account, returns `{ "user_id" }`; `404` when the token is wrong, used or expired |

How accounts, sessions and set-password links work is in
[Authentication](auth.md).
