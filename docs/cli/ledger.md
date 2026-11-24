# CLI: `ledger`

The double-entry ledger: accounts that count one unit (a currency, or points, credits, pieces
a plugin declares) for the plugin that opened them, and the transfers between them, never
changed or removed. Only plugin code moves money ([Plugin API](../plugin-api.md#the-ledger));
the command line reads, for people and agents with read access. The same operations answer
over REST at `/api/ledger.<verb>`. Back to the [CLI reference](../cli.md).

Amounts are whole numbers of the unit's smallest step: `1250` PLN is 12.50 zł, `1250`
`loyalty.points` is 1,250 points. Balances read on the side the account's kind grows on.

## `ledger accounts`

Accounts in the order they were opened, a page at a time.

| Field | Type | Default |
|---|---|---|
| `--plugin` | text | every plugin's |
| `--name` | text | every name |
| `--holder` | text | anyone's: a record's or a person's id |
| `--unit` | text | every unit; a unit matches its per-record units too |
| `--after` | text | the first page; the `next` the last page answered |
| `--limit` | 1 to 200 | `50` |

Output: `{ "accounts", "next" }`, each account with its owner, name and label, kind, limit,
holder, key, unit and scale, posted, pending and available balances, its four totals and
whether it is closed.

```
$ publr --as-admin ledger accounts --plugin loyalty --unit loyalty.points
```

## `ledger account`

One account, as `ledger accounts` lists each.

| Field | Type | Default |
|---|---|---|
| `--id` | text | required |

## `ledger balance`

An account's unit, posted balance, holds, available balance and four totals; with `--at`
(Unix milliseconds) the posted balance as it stood then.

## `ledger history`

An account's transfers, newest first: each with its side, its amount on this account
(positive when it grows the balance), the balance after it, its status (`posted`,
`pending`, `voided`, `expired`) and what it is about.

| Field | Type | Default |
|---|---|---|
| `--account` | text | required |
| `--about` | text | any record |
| `--from`, `--to` | Unix ms | any time |
| `--before` | text | the newest; the `before` the last page answered |
| `--limit` | 1 to 200 | `50` |

## `ledger find`

A page of the transfers that match every filter given, on accounts the caller may read,
oldest first: an order's money story, a page at a time.

| Field | Type | Default |
|---|---|---|
| `--about` | text | any record |
| `--detail` | text | any finer record |
| `--account` | text | any account |
| `--name`, `--plugin` | text | any name; `--plugin` says whose accounts the name is |
| `--reason` | text | any reason |
| `--after` | text | the first page; the `next` the last page answered |
| `--limit` | 1 to 200 | `50` |
| `--newest` | flag | oldest first |

At least one of `--about`, `--detail`, `--account` and `--name`: each is read through an
index, so a read costs what it answers, never the size of the ledger.

## `ledger totals`

Posted and open-hold amounts per reason and unit over the transfers that match:
`--about` a record, `--detail` a finer one, of one `--reason`, on one `--account`, or the
accounts of one `--name` (with `--plugin`), between `--from` and `--to`. With `--details`
(up to 200 finer records) there is one sum per detail, reason and unit. The database adds
them up: no transfer is read.

## `ledger get`

One transfer by core's id (`--transfer`): its accounts, amount, reason, status, maker and
author, the hold it settles or what settled it, its reversals, a conversion's rate, source
and other leg, the chain it was posted in.

## `ledger check`

Recomputes every account's totals from its transfers and each unit's sums, and answers what
differs: nothing, unless there is a bug. Changes nothing.

```
$ publr --as-admin ledger check
{
  "in_balance": true,
  "units": [ { "unit": "PLN", "debits_posted": 2800, "credits_posted": 2800,
    "difference": 0, "in_balance": true } ],
  "accounts": []
}
```

## Writes

`ledger open`, `transfer`, `hold`, `post_hold`, `void_hold`, `chain`, `reverse`, `convert`,
`close` and `reopen` are plugin code's only: from the command line they are refused
(`Denied`).
