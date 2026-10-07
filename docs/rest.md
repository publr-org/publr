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
fragments, `<mount>/_app/<path>` for its stylesheet (`app.css`) and generated assets, and
its `public/` files at their own paths (`<mount>/robots.txt`). A built
page answers with an `ETag`, a rendered one with `no-store`; `X-Publr-Served` says which
(`file`, `memory`, `render`). With no app there, `/` opens the admin.

## Media

`GET /media/<key>` serves a file of the media library by its key
(`2026/10/harbour-a1b2c3.jpg`). `?w=` and `?h=` resize a JPEG or PNG, never larger than
it is; with both, `?fit=cover` scales it until it covers them and then crops, otherwise
it crops at full size, around the file's focal point or `?fp=x,y` (percent). `?q=` is
the quality, 1 to 100 (90). A browser whose `Accept` takes WebP gets WebP. Copies are
cached beside the originals. A public file answers `Cache-Control: public,
max-age=31536000, immutable` with an `ETag` of its hash (and the copy's suffix) and
`304` to a match; a private one is `404` to anyone not signed in and `private, no-store`
to the rest. Every answer carries a Content-Security-Policy with `sandbox`, so an SVG or
a text file opened on its own runs nothing. A file larger than one response (2 MiB)
answers `413` to a request for the whole file; ranges of it, and its resized copies, are
served.

`POST /media/upload?filename=<name>[&folder=<id>]` adds a file to the library: the
body is the file's bytes as they are (no form, no base64), taken as they arrive and
kept in the library's uploads area until the whole file is in; then `media upload`
checks and adds it, and the answer is `201` with the file as `media list` gives it.
Signed-in only, same origin, with `X-Csrf-Token`; up to 32 MiB. A file is read in part
with `Range` (`206`), which is how a browser plays a video, so a file larger than one
response is served that way.

`GET /admin/avatar/<md5>` is the signed-in user's Gravatar from the admin's own address:
fetched once on a thread of its own and kept beside the media cache, served after that
(a clear pixel until then, or when there is none).

## Served under a path

A project whose `--url` has a path (`https://example.com/site`) is served under it: every
route above answers at `/site/...`, and a request outside it is not the project's (404).
Every address it sends back carries the path: pages, assets, island and script requests,
redirects, and the paths its cookies are kept for.

## Health

| Route | What |
|---|---|
| `GET /api/health` | `{ "version", "echo", "caller" }`; `caller` is who you are (`anonymous`, or a user id) |

## The CLI next to the server

| Route | What |
|---|---|
| `POST /_publr/apps/load` | from `publr apps load`, with the same key: the apps read from their folder again and swapped in; answers `{ "loaded" }` or `{ "error" }` |
| `POST /_publr/cli` | body `{ "args", "password" }`: a command the CLI sends the server running for its database, run as the CLI would run it; answers `{ "code", "out", "err" }`. Only with the key this run of `serve` wrote beside the database (`X-Publr-Operator`), else `403`; see [CLI](cli.md#while-a-server-runs) |

## A device elsewhere

| Route | What |
|---|---|
| `POST /api/cli` | body `{ "args" }`: a command sent by `publr --site <address>`, run here as the device whose token comes in `Authorization: Bearer`; answers `{ "code", "out", "err" }`. `--as` is refused; without a device's token, `401` |

Any route takes a device's token in `Authorization: Bearer <token>` instead of the
session cookie, and then needs no CSRF token. The token comes from signing in by link:
`POST /api/device/start`, the person approves at the link it answers,
`POST /api/device/poll` until `approved`, then `POST /api/device/claim` once
([Authentication: Devices](auth.md#devices)).

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
