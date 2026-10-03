# Queries

Content is read with GROQ, the query language at [spec.groq.dev](https://spec.groq.dev).
A query asks for records and shapes the answer, nested records included. Publr reads
only what a filter can match: its `_type`, `_id` and `field == value` clauses are looked
up through indexes, so `*[_type == "variant" && product == ^._id]` inside a product reads
that product's variants, not every variant.

```
publr record query --query '*[_type == "product" && slug == $slug][0]{
  title,
  "variants": *[_type == "variant" && product == ^._id] | order(price.GBP) {
    title, price, "product": product->title
  }
}' --params '{"slug":"earl-grey"}'
```

The same operation is `GET /api/record/query?query=…&params=…`.

## What a query can say

All of GROQ as specified in GROQ-1.revision5: filters, projections with `...` and
conditional `=>` entries, traversals (`items[]`, `items[0]`, `items[2..5]`, `items[-1]`),
`->` (`author->name`, `chapters[]->{ title }`), `^` to outer scopes, `$params`,
arithmetic, `match`, `in` with arrays and ranges, `| order(...)` and `| score(...)`, and
the functions: `count`, `coalesce`, `select`, `defined`, `length`, `references`, `round`,
`string`, `lower`, `upper`, `dateTime`, `now`, `boost`, and the `array::`, `string::`,
`math::` and `dateTime::` namespaces.

Not supported, on purpose: the extensions (Portable Text, geo, documents), custom
functions, delta mode with `diff::` and `delta::`, and the vendor functions `identity()`
and `path()`. A query using them is refused, saying so.

References are record ids: `product == ^._id` compares them, and `->` follows a string id
as it follows `{ "_ref": id }`. A record is its fields with `_id`, `_type`, `_createdAt`
and `_updatedAt`.

## What it reads

A query reads only what the caller may read, decided where the statement is built, at
every level of nesting:

- **Types.** The types the caller's access reaches; a visitor's are the public ones. A
  query naming a type out of reach is refused (`Denied`).
- **Statuses.** `perspective: published`, the default and a visitor's only one, reads
  live records. `perspective: all` reads every status the caller's access allows.
- **Fields.** A field the caller's access hides is as if the type had none.
- **Own records.** Access limited to one's own records reads only those.

A reference to a record the caller may not read is `null`, and the answer's `problems`
names the record and why:

```
{ "result": [{ "title": "Orphan", "by": null }],
  "problems": [{ "id": "…", "reason": "status",
                 "message": "a reference to … was made null: it is not published, …" }] }
```

## Limits

A query is at most 16 KiB and nests at most 48 deep. Its answer is at most 2 MiB, and it
may do a fixed amount of work: about a second for a page or a person, a plugin's own CPU
limit for a plugin. Past either it is refused (`TooLarge`, `TooMuchWork`) with what to
change: narrower filters, or a slice.
