# `health`

Site Health: what is quietly wrong in the project, listed so it never spreads unseen, each
case decided on its own, in two sections: broken references and translations. A broken
reference is a record pointing at one in the trash (`deleted`), one gone for good (`gone`),
or one whose type is no longer shared with the app their own type lives in (`not_shared`). The cases are worked out from
the references themselves; only "keep as is" is stored. A reference to a Private record is
not a case: a reader without access is the design working. Administrators only. Back to the
[CLI reference](../cli.md).

| Command | What it does |
|---|---|
| `health list [--kept] [--after <target>] [--limit <n>]` | One case per record pointed at (per app, for a type not shared), 50 a page (`--limit` up to 200, `--after` a page's `next`): `target`, `type`, `title`, `reason`, `app`, the first ten records still pointing at it and `holders_total`, whether it is kept; kept ones only with `--kept`, counted either way |
| `health count` | The cases not kept as they are, plus the translation disagreements not picked yet: what the Settings sidebar shows beside Site Health |
| `health keep --target <id> [--app <name>]` | Leave a case as it is: the editor's card and the site's restricted payload stay, the case leaves the list until its reason or the number of records pointing changes |
| `health unlink --target <id> [--app <name>]` | Take the pointer out of every record of the case, live and pending |
| `health translations` | Where installed translations disagree: per language, each message with every plugin's version (`provider`, `first_party`, `text`), the one `chosen` (empty while the first-party one shows), how many are `open`, and each language's `coverage` per domain |
| `health choose_translation --locale <code> --id <message> --provider <plugin> [--context <c>]` | Show that plugin's translation of the message; an empty `--provider` goes back to the first-party one |
| `health missing_translations --locale <code> --domain <name>` | The messages of a domain (`publr`, or a plugin's name) the language does not translate yet, as a `.pot` |

A case is also settled by restoring the record (`record transition --transition restore`) or by sharing
its type with the app again (`content_type update`), which the admin's Restore and "Share
with … again" do.
