# CLI: `user`

Accounts, roles, passwords and signing in. The first admin comes from
[`publr init`](site.md); after that, create accounts with `user create`. Two
roles exist: `admin` may do everything, `editor` may manage content but not
users or settings. `sign_in`, `sign_out` and `set_password` are open to
anyone; the rest needs an admin (`--as <admin>` or `--as-admin`). The design
behind these commands is in [Authentication](../auth.md); the same operations
back the `/api/auth/*` routes in [REST API](../rest.md). Back to the
[CLI reference](../cli.md).

## `user create`

Create a user. Admins only (`--as <admin>` or `--as-admin`).

| Field | Type | Default |
|---|---|---|
| `--email` | text | required |
| `--display_name` | text | required |
| `--role` | `admin|editor` | `editor` |
| `--password` | text | generated when omitted (or `PUBLR_PASSWORD`) |
| `--password_link` | boolean | `false`: create inactive and return a set-password link instead of a password |

Output: `{ "user_id", "role", "password", "link": { "path", "expires_at" } }`
(`password` only when generated, `link` only with `--password_link`).

```
$ publr --as ada@example.com users create --email new@example.com --display_name New --password_link true
{
  "user_id": "9b1e...",
  "role": "editor",
  "password": null,
  "link": { "path": "/auth/set-password?token=6f3a...", "expires_at": 1789650000000 }
}
```

Prefix the path with your site's URL and hand it to the person.

## `user password_link`

Issue a fresh one-hour set-password link for any user (by id or email); the
previous link stops working. Admins only.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required |

Output: `{ "user_id", "link": { "path", "expires_at" } }`.

## `user get`

One account with its custom fields: `fields` holds one group per custom
field group that applies to the account (destination `user`, role rules
matching), each with its fields; `document` holds the values as JSON, one
object per group, so a value's path is `<group handle>.<field>`. Admins only.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |

Output: `{ "user": { "id", "email", "display_name", "role", "created_at", "active" }, "fields", "document" }`.

## `user update`

Rename a user or change their role; the email and password stay. With
`--document`, replace the custom field values too, validated against the
groups that apply to the account's new role. Admins only. The last admin
cannot be made an editor, and you cannot change your own role.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |
| `--display_name` | text | required |
| `--role` | `admin|editor` | required |
| `--document` | JSON text | omitted: the values stay |

Output: `{ "user_id", "role" }`.

## `user validate`

Check custom field values for an account without saving, with the rules
`user update --document` applies. Admins only.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |
| `--document` | JSON text | required |

Output: `{ "valid", "problems": [{ "path", "message" }] }`.

## `user delete`

Delete a user and sign out every session they have; what they created
stays, attributed to their id. Admins only. You cannot delete yourself or
the last admin.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |

Output: `{ "user_id", "sessions_revoked" }`.

## `user set_password`

Redeem a set-password link: sets the password, activates the account and
signs out every existing session. Anyone holding the token may call it; a
wrong, used or expired token answers `not found`.

| Field | Type | Default |
|---|---|---|
| `--token` | text | required |
| `--password` | text | required (or `PUBLR_PASSWORD`) |

Output: `{ "user_id" }`.

## `user list`

List users. Admins only.

Output: `{ "users": [ { "id", "email", "display_name", "role", "created_at", "active" } ] }`;
`active` is false until a password is set.

## `user sign_in`

Sign in. Anyone may call it. Fails with `wrong email or password` (same message
for unknown accounts) or, after repeated failures, `too many failed attempts`.

| Field | Type | Default |
|---|---|---|
| `--email` | text | required |
| `--password` | text | required (or `PUBLR_PASSWORD`) |

Output: `{ "token", "user_id", "expires_at" }`. The token is the value of the
`publr_session` cookie; over HTTP use `POST /api/auth/sign-in` instead, which sets
the cookie for you.

## `user sign_out`

Sign out: revoke a session token. Anyone holding the token may call it.

| Field | Type | Default |
|---|---|---|
| `--token` | text | required |

Output: `{ "destroyed" }` (false when the token was unknown or already expired).
