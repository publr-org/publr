# CLI: `rail`

The rail holds Overview, Content and Media, then the pages the person pinned, in the order
pinned. Nothing else adds to it: plugins register pages (listed under Settings) and
sections (listed in Content), and each person pins the ones they use, here or with the pin
at the end of a row in those sidebars. A pin names a page: a core one by its address below
`/admin/` (`settings/users`, `trash`, `structure`, `settings/<handle>` for a settings
section), a plugin's by the plugin and its page (a page's path, a settings page's address,
or `section/<handle>` for a section, named by its first type). Pins are each person's own;
an administrator may also pin a page for everyone (`--for_everyone true`): it comes first
on every rail, and a person who unpins it hides it from their own. A page they may not see,
or one whose plugin is gone, is not drawn. Up to 16 each. Back to the
[CLI reference](../cli.md).

| Command | What |
|---|---|
| `rail list` | Everyone's pins the caller kept (`shared`), then the caller's own, top to bottom |
| `rail pin --page <page> [--plugin <name>] [--for_everyone true]` | Pin a page below the others; invalid unless it exists; for everyone: administrators only |
| `rail unpin --page <page> [--plugin <name>] [--for_everyone true]` | Take it off the rail (an everyone pin: hide it from the caller's); for everyone: administrators only |
