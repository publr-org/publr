# CLI: `design`

An app's design system and its moodboard. The admin's Design area draws both
([Admin](../admin.md)); agents read and write them here. Back to the
[CLI reference](../cli.md).

## `save_system`

The app's design tokens and fonts, written into its `app.zon` as `.tokens` and `.fonts`
(see [Apps](../apps.md)), each list whole; the rest of the file is kept as written. Then
the apps are loaded again, so every page shows the change. Administrators only, and not a
device that may save drafts only.

- A token is `{name, value}`: a name of lowercase letters, digits and `-`, starting with a
  letter, up to 64; a value of one CSS value, up to 512, without `;`, `{`, `}` or a line
  break.
- A font is `{family, url}`: the url an `https://` stylesheet, up to 32 fonts.

When the apps do not load after the write, it fails with `NotLoaded` and why; the file
stays written.

```
$ publr design save_system --app www --tokens '[{"name":"color-brand","value":"#2f5d54"}]' \
    --fonts '[{"family":"Inter","url":"https://fonts.googleapis.com/css2?family=Inter"}]'
{ "path": "www/app.zon", "tokens": 1, "fonts": 1 }
```

## `moodboard`

The app's board: every card in the order it was added, for an agent to learn what the
site should look like. Editors and administrators.

A card is `{id, kind, x, y, w, h?, note?, ...}`: `id` its record's, `kind` one of `note`
(`text`), `link` (`url`, `title`), `image` (`src`, `alt`), `color` (`value`), `font`
(`src`, `family`, `file`, `weight`, `weight_max` for a variable font, `italic`) or `figma` (`url`, `title`, `thumbnail`, `colors`, `fonts`,
`status`, `error`), and `note` why it is there. A field a card does not hold is `null`.

## `save_moodboard`

The whole board, `{app, items}`; the server makes the app's `moodboard_item` records
match it. A card whose `id` is one of its records saves into it, only when it changed; any
other card (a new one, with the editor's own id) becomes a new record; a record the board
no longer holds goes to the trash. It answers `{items}`, the board as sent with every
`id` its record's, so the editor keeps those from then on. Up to 200 cards. Editors and
administrators.
