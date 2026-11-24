# CLI: `money`

Amounts written as the site writes them: its currencies' symbols, formats and separators.
Plugins call it to show money on their own pages. Back to the [CLI reference](../cli.md).

## `money text`

Writes an amount by currency, in minor units (`{"GBP":1745}` is £17.45), in the site's main
currency as pages write money. Without it, the amount's first currency is written, with its
code when the site does not list it.

| Field | Type | Default |
|---|---|---|
| `--amount` | money | required |
| `--plain` | true/false | `false`: written as typed into a field, `1234.56` |

Output: `{ "text" }`.

```
$ publr --as-admin money text --amount '{"GBP":1745,"EUR":2000}'
{
  "text": "£17.45"
}
```

## `money texts`

Many amounts at once, each written as `money text` writes it, in the same order: up to
200 a call. A plugin's page writes a page of an order's lines and charges in one call.

```sh
$ publr --as-admin money texts --amounts '[{"GBP":1745},{"GBP":200}]'
```

## `money main`

The store's main currency: the first the site lists. Prices are entered in it and orders keep
it; other currencies are conversions from it. Empty when the site lists none.

Output: `{ "currency", "example" }`.

## `money read`

An amount as typed in the admin (`3.95`, `3,95`) in the main currency, by its code in minor
units. Refused when it is not a number or has more decimals than the currency.

| Field | Type | Default |
|---|---|---|
| `--text` | text | required |

Output: `{ "amount" }`, e.g. `{ "amount": { "GBP": 395 } }`.
