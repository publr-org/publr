# CLI: `user`

Accounts, roles, passwords and signing in. The first admin comes from
[`publr project init`](project.md); after that, create accounts with `user create`. An
account holds the roles it is given (none unless asked) and may call what any of them grants: core's
`admin` (everything) and `editor` (content, not users, structure or settings), and
whatever the plugins declare ([`role list`](role.md)). `sign_in`, `sign_out` and `set_password` are open to
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
| `--roles` | role names, comma-separated | none: an account holding no role can do nothing until an admin gives it one; with `--user_type`, exactly the type's roles |
| `--password` | text | generated when omitted (or `PUBLR_PASSWORD`) |
| `--password_link` | boolean | `false`: create inactive and return a set-password link instead of a password |
| `--user_type` | text | none when empty; else a type of user a plugin registers ([`user_type`](user_type.md)) the account holds; holding no role but the type's, it signs in only to the apps the type opens |

Output: `{ "user_id", "roles", "password", "link": { "path", "expires_at" } }`
(`password` only when generated, `link` only with `--password_link`).

```
$ publr --as ada@example.com user create --email new@example.com --display_name New --roles editor --password_link true
{
  "user_id": "9b1e...",
  "roles": ["editor"],
  "password": null,
  "link": { "path": "/admin/welcome?token=6f3a...", "expires_at": 1789650000000 }
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
field group that applies to the account (destination `user`, a role rule
matching one of its roles), each with its fields; `document` holds the values as JSON, one
object per group, so a value's path is `<group handle>.<field>`. Admins only.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |

Output: `{ "user": { "id", "email", "display_name", "roles", "created_at", "active" }, "fields", "document" }`.

## `user update`

Rename a user or change their roles; the email and password stay. With
`--document`, replace the custom field values too, validated against the
groups that apply to the account's new roles. Admins only. The last admin
cannot lose the `admin` role, and you cannot take it from yourself.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |
| `--display_name` | text | required |
| `--roles` | role names, comma-separated | required |
| `--document` | JSON text | omitted: the values stay |

Output: `{ "user_id", "roles" }`.

## `user validate`

Check custom field values for an account without saving, with the rules
`user update --document` applies. Admins only.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |
| `--document` | JSON text | required |

Output: `{ "valid", "problems": [{ "path", "message" }] }`.

## `user delete`

Delete a user into the trash and sign out every session they have; what they
created stays, attributed to their id. `trash restore` brings the account back
with its roles and fields, signed out. Admins only. You cannot delete yourself
or the last admin.

| Field | Type | Default |
|---|---|---|
| `--user` | text | required: id or email |

Output: `{ "user_id", "sessions_revoked" }`.

## `user set_password`

Redeem a set-password link: sets the password, activates the account,
signs out every existing session and stops the account's devices (the CLI and
agent tools sign in again). Anyone holding the token may call it; a wrong,
used or expired token answers `not found`.

| Field | Type | Default |
|---|---|---|
| `--token` | text | required |
| `--password` | text | required (or `PUBLR_PASSWORD`) |

Output: `{ "user_id" }`.

## `user sign_up` and `user request_reset`

A visitor's own account on an app, called from the app's pages (`POST /api/auth/sign-up`,
`POST /api/auth/reset`): `sign_up` makes an inactive account of a user type that allows it
(`--user_type`, `--email`, `--display_name`); `request_reset` (`--email`) is for an account of a
type that opens the app. Each sends a one-hour set-password link to the type's page on the
app, redeemed with `user set_password`. Output: `{ "sent": true }`, whether or not an account
exists. Staff never use them.

## `user add_type` and `user remove_type`

Give an account a type of user, or take one (`--user`, id or email; `--user_type`). An account
holds any number of types, staff included: an administrator may also be a customer.
`add_type` gives the roles the type gives too; `remove_type` takes them, keeping one another
type it holds gives. Neither touches another role, the password or a sign-in. Administrators,
and plugins with `users.write`, or `users.own` for their own types on any account. Output:
`{ "user_id", "user_types", "roles" }`, as they are now.

## `user list`

List users, oldest first, a page at a time. Admins only.

| Field | Type | Default |
|---|---|---|
| `--query` | text | every account; else those whose name or email holds it |
| `--limit` | number | 50, up to 200 |
| `--offset` | number | 0 |
| `--user_type` | text | staff when empty (accounts holding no type, or a role no type gives); else the accounts holding that type |

Output: `{ "users": [ { "id", "email", "display_name", "roles", "created_at", "active",
"user_types" } ], "total" }`; `active` is false until a password is set, `total` counts every
account the query matches. Settings › Users lists staff; a type's plugin lists its own. `user options` (ids and names for pickers, for editors too) pages the same
way.

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

## `user end_sessions`

Sign an account out everywhere, or everyone. Administrators only; device tokens are left
alone. Name exactly one of the three.

| Field | Type | Default |
|---|---|---|
| `--user_id` | text | "" |
| `--email` | text | "" |
| `--everyone` | bool | false |

Output: `{ "ended" }`, how many sessions ended.

## `user language` and `user set_language`

The language the admin speaks to the caller: `chosen` (empty: the site's), `site`, `shown`,
the `choices` (English and every language a plugin translates the admin into) and whether
the caller ever `answered` (until then the site's default, else English). `set_language
--language <code>` chooses one of the choices, or empty for the site's.
