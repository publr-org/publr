# CLI: `identity`

Signing in as who a provider says you are. A provider plugin (`github`, `google`)
proves the identity; these operations keep which account it belongs to and decide who
gets in. The rules are in [Auth](../auth.md#signing-in-with-a-provider). Back to the
[CLI reference](../cli.md).

## `sign_in`

Administrators, and the system: `/auth/<provider>/callback` calls it once the plugin has
verified who someone is, so nobody claims an identity by hand. Finds the account by provider and id,
else links the account with that verified email, else refuses with `wrong email or
password`, unless sign-up is open: then it creates an account with the configured role.
Returns a session token like `user sign_in`, and `created` when the account is new.

## `configure`

Administrators only. `--open_sign_up <role>` lets an identity nobody holds create an
account with that role, from a verified email; any declared role but `admin`. Empty closes
sign-up again, the default: only accounts that exist sign in through a provider.

```
$ publr --as ada@example.com identity configure --open_sign_up editor
{ "open_sign_up": "editor" }
```

## `status`

Administrators only. The role in force, empty when sign-up is closed.

## `providers`

Anyone may call it: the providers this site offers, each with `name`, `label`, `icon` and
`path` (`/auth/<name>`, where its button goes). A provider is offered when its plugin is
compiled in and its credentials are in the environment. Nothing is written.

## `link`

Administrators, and the system: adds an identity to an account (`--user`, id or email),
for a signed-in person who has just proved it with a provider. An identity linked already, anywhere, is a conflict; an account
holds at most sixteen.

## `list`

An account's own identities, oldest first: `provider`, `id`, `email`, `created_at`,
`last_used_at`. `--user <id>` names another account, for administrators and the system.
`editor` grants it.

```
$ publr --as ada@example.com identity list
{ "identities": [ { "provider": "github", "id": "583231", "email": "ada@example.com", ... } ] }
```

## `unlink`

Drops one of the account's own identities (`--provider`, `--id`; `--user <id>` names
another, for administrators and the system). `editor` grants it. The last identity of an
account without a password stays: dropping it would lock the account out, a conflict. An
identity the account does not hold is not found.
