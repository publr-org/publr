# CLI: `content_type`

Content types are data: a handle, names, a kind (`record`, the default, holds
any number of records; `settings` exactly one; `component` none, its fields are
for other types to reuse), `url` (`posts`: where its records live on the site;
a type with a url is public and needs a slug field), whether the type is public, and a list of
fields, which may be empty. Records take their title from `title_field` (default
`title`) when a field of that name exists. Definitions are JSON (`publr
content_type create --help` spells out every key and field kind). Signed-in
users may read types; changing them needs an admin. Anonymous callers never see type definitions, only the live records
of public types. Back to the
[CLI reference](../cli.md); how content is modelled is in
[Architecture](../architecture.md#content).

| Command | What |
|---|---|
| `content_type create --definition <json>` | Create a type; admins only |
| `content_type update --type <handle\|id> --definition <json> [--drop_content true]` | Change a type; existing records follow (see below) |
| `content_type get --type <handle\|id>` | Read the full definition |
| `content_type list` | List types |
| `content_type delete --type <handle\|id> [--force true]` | Delete; refuses while records exist unless forced |
| `content_type validate --definition <json>` | Report every problem without saving |

Field kinds: `string`, `text`, `richtext`, `slug`, `email`, `url`, `boolean`,
`integer`, `number`, `datetime`, `select`, `media`, `reference`, `terms`
(the terms of one taxonomy, `"options":{"taxonomy":"topics"}`, a form control
for composing terms with other fields; a taxonomy attaches itself to types
through its own `applies_to`, see [taxonomy](taxonomy.md)), `group`,
`repeater`, plus any a plugin declares, named `<plugin>.<kind>`; an unknown
kind is refused. A field can be `required`, `unique` (a single string, email,
url or integer field whose value no other record of the type may hold; refused
as a conflict on write and again when pending changes go live), `searchable`
(full-text), `many` (a list of values of its kind: any kind but slug and
group), carry a `help` line (up to 255
characters, shown under its control) and a `default` (the text its control
posts, `1` for a boolean, a `datetime-local` or `YYYY-MM-DD` text or `now` for
a date; put into a new record wherever the field is left out; not for slug,
richtext, media, reference or a unique field), and carry `options`:

- bounds: `min`, `max`, `step` (numbers; for a datetime, milliseconds bounding
  the allowed span), `min_len`, `max_len`, `words_min`, `words_max`,
  `items_min`, `items_max` and `distinct` (a list or repeater), `preset`
  (`any`, `digits`, `letters`, `alphanumeric`, `no_spaces`, `lowercase`,
  `uppercase`, `phone`) and `pattern` (`*` any run, `?` one character, `#` a
  digit, `@` a letter) on string and text, `choices` (a select's values, or
  the only values a number may take) with `labels` (one per choice, or none);
- `messages` (`length`, `range`, `size`, `types`, `dimensions`, `items`,
  `pattern`, `words`, `domain`, `scheme`, `host`, `reserved`, `choices`): what
  an editor reads instead of the built-in message when the rule refuses;
- the kind's own group: `text` (`format`: `plain`, `markdown`), `date`
  (`format`: `datetime`, `date`; `from_now`), `slug` (`lock_on_publish`,
  `reserved`), `email` (`domains`, `lowercase`), `url` (`schemes` from http,
  https, mailto, tel, empty for http and https; `hosts`), `boolean`
  (`true_label`, `false_label`, `control`: `toggle`, `checkbox`, `radio`),
  `number` (`unit`, `unit_after`, `decimals`, `control`: `input`, `slider`,
  `rating`), `select` (`control`: `dropdown`, `list`), `reference` (`create`,
  `link`, `live_only`, `on_delete`: `keep`, `block`, `clear`: what `record
  purge` does to a pointer at the purged record), `container` (`collapsed`,
  `label_field`, `add_label`) and `media` (`size_min`, `size_max` in bytes,
  `types` from image, video, audio, pdf, document, spreadsheet, presentation,
  text, code, archive, `width_min`, `width_max`, `height_min`, `height_max` in
  pixels, `create`, `link`; kept on the definition now, checked when the
  media library lands);
- `source` for slugs, `to` for references (the record types it may point at,
  by handle, empty for any record type), `rows`, `placeholder`.

Every field can be filtered on; a repeater cannot contain another repeated
field.

Changing a type: added fields need nothing. A removed field is refused while
records hold values for it, unless `--drop_content true` deletes them. A kind
change converts values row by row when it is allowed and every value fits
(string to text/richtext/slug/email/url/select/integer/number, text to
richtext and back, slug/email/url/select to string or text, integer to number
or string, number to string or integer if whole, boolean to string, datetime to
integer, single reference to many, many to single when no record has more than
one); otherwise the update is refused. References, images, groups and
repeaters never convert to another kind: remove and re-add.

```
$ publr --as ada@example.com content_type create --definition '{"handle":"post","name":"Post",
  "public":true,"fields":[
  {"name":"title","label":"Title","kind":"string","required":true},
  {"name":"slug","label":"Slug","kind":"slug","options":{"source":"title"}},
  {"name":"body","label":"Body","kind":"richtext","searchable":true}]}'
{ "id": "7c2d…", "handle": "post" }
```
