# CLI: `user_type`

The types of user plugins register (`customers` registers `customer`): people with an account
on the site who are never staff, and the apps each type may sign in to. They sign in, set
passwords and keep sessions like anyone ([Auth](../auth.md#user-types)); an account of a type
is somebody only in the apps its type opens. Back to the [CLI reference](../cli.md).

## `list`

Every type a plugin registers, compiled in or installed, with the apps its people may sign in
to now. Administrators, and plugins.

```
$ publr --as ada@example.com user_type list
{ "types": [ { "name": "customer", "label": "Customer", "plugin": "customers", "apps": ["shop"] } ] }
```

## `set --user_type <name> --apps <list>`

Replaces the apps the type's people may sign in to (`app.zon`'s `.name`); none: nowhere. It
counts from the next request. Administrators only; Settings › User types is the same switch
per app. Not found for a type no plugin registers.

```
$ publr --as ada@example.com user_type set --user_type customer --apps shop,account
{ "user_type": "customer", "apps": ["shop", "account"] }
```

An account of a type is made with `user create --user_type customer --roles <its role>` (or by
the plugin's own sign-up operation), and listed with `user list --user_type customer`.
