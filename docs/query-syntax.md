# MacFSW Query Syntax

The monitor command bar accepts a filter language parsed by
`MacFSWQueryParser` (`Sources/MacFSWCore/Query/`). This document is the
specification; two executable specifications enforce it —
`QueryGoldenCorpusTests` (examples) and `QueryPrinterRoundTripTests`
(structure, via the `parse ∘ print == identity` property). When this document
and the code disagree, a test fails.

## Grammar (EBNF)

```
query        = or-expr ;
or-expr      = and-expr , { OR , and-expr } ;
and-expr     = unary-expr , { [ AND ] , unary-expr } ;   (* juxtaposition = AND *)
unary-expr   = { NOT } , primary ;
primary      = "(" , or-expr , ")" | term ;
term         = field-term | text-term ;
field-term   = field-key , operator , value , { "," , value } ;
operator     = "!=" | ">=" | "<=" | "=" | ":" | ">" | "<" ;
text-term    = word ;                                    (* full-text contains *)
```

Precedence: `NOT` binds tighter than `AND`; `AND` tighter than `OR`.
`op:rename OR op:unlink path:/Library` therefore means
`op:rename OR (op:unlink AND path:/Library)`.

## Lexical rules

- Tokens split on unquoted whitespace; `(` and `)` are structural outside
  quotes.
- `"` toggles verbatim mode; quote characters are removed and do not nest or
  escape. Quoting protects whitespace and parens — **not** commas, operators,
  or keywords (`"AND"` is still the AND keyword; `"op:rename"` is still a
  field term).
- `AND` / `OR` / `NOT` are case-insensitive keywords, classified after quote
  stripping.
- A leading `-` on a token longer than one character is sugar for `NOT`; the
  remainder is always a term and is never re-read as a keyword (`-AND`
  searches for the text "AND").
- Field split: the **leftmost** operator occurrence in a word wins; at equal
  position the longest operator wins (`>=` beats `>`). Field keys resolve
  through `MacFSWQueryFieldCatalog` aliases (case-, `_`- and `-`-insensitive).
- Commas always separate values; each value is trimmed of surrounding
  whitespace; empty segments are dropped.

## Semantics

| Operator | Meaning |
|---|---|
| `:` | contains (case-insensitive); `*` / `?` switch to glob equality |
| `=` | equals (case-insensitive) |
| `!=` | not equals — with multiple values, **none** may match (De Morgan) |
| `>` `>=` `<` `<=` | numeric comparison; `0x` hex accepted |

- Multiple comma-separated values are OR within a predicate for `:` and `=`.
- Enum fields (`op:`, `class:`) and boolean fields (`platform:`, `apple:`,
  `mutation:`; true/yes/1/on, false/no/0/off) match exactly; free-text fields
  use contains. Field list and aliases: `MacFSWQueryFieldCatalog`.
- A bare word is a full-text contains over all event fields.

## Error tolerance (lenient parse + diagnostics)

Parsing never fails. Degenerate input is healed, and each healing is named by
a `MacFSWQueryDiagnostic` from `MacFSWQueryParser.parseDetailed` — the invariant
`parseDetailed(s).query == parse(s)` holds for every input. The command bar
shows an orange warning icon whose tooltip carries the messages.

| Input class | Healed interpretation | Diagnostic kind |
|---|---|---|
| Unknown field key (`porcess:x`) | full-text contains of the whole word | `unknownField` |
| Known field, empty value (`op:`) | full-text contains of the whole word | `emptyValue` |
| Unclosed `(` | group runs to the end | `unbalancedOpenParen` |
| Stray `)` | it and any following input are ignored | `unexpectedCloseParen` |
| Unclosed `"` | quote runs to the end | `unterminatedQuote` |
| Trailing `AND`/`OR`, `NOT` without operand | operator dropped | `danglingOperator` |

## Representational limits

Enforced/documented by the canonical printer (`MacFSWQueryPrinter`):

- Values cannot contain `"` (quotes never escape) or `,` (always splits).
- A `<` or `>` comparison whose first value starts with `=` merges into
  `<=`/`>=` when written out; quoting cannot prevent this because field
  splitting runs on quote-stripped token text.

## Changelog

- **2026-07 re-architecture:** field terms split at the leftmost-longest
  operator (previously a fixed scan order mis-split words like
  `path:/foo=bar` into silent full-text matches); lenient healing now emits
  diagnostics surfaced in the command bar. Everything else is bit-identical
  and guarded by the golden corpus and the frozen wire-format fixture.
