# ADR-002: Tokenizer and lossless syntax tree

- Status: Accepted
- Date: 2026-07-11
- Owners: ZigCSS core parser maintainers
- Roadmap: `TOK-001` through `SYN-001`, then parser and emitter milestones

## Context

The inherited parser scans bytes directly and splits important grammar at characters such as whitespace, semicolons, braces, parentheses, and commas. That design cannot distinguish `.a.b` from `.a .b`, preserve delimiters nested inside functions or strings, represent functional pseudo-classes and attributes, or attach reliable source locations.

The normative behavioral baseline is the CSS Working Group's [CSS Syntax Module Level 3](https://drafts.csswg.org/css-syntax/), including its tokenization algorithms, parse-error behavior, token metadata, and component-value parsing model. The referenced document is a living Editor's Draft; ZigCSS fixtures record the behavior implemented by each package so later specification changes are reviewed rather than inherited silently.

## Decision

ZigCSS will use a staged representation:

```text
SourceFile bytes
  -> CSS tokenizer + trivia
  -> lossless component values and nested blocks/functions
  -> typed CSS AST
```

### Source and spans

- `SourceFile` retains the original UTF-8 bytes for diagnostics, raw spelling, and emission fallback.
- Every token, trivia item, component value, and transformable AST node carries a half-open `Span` expressed as original byte offsets: `[start, end)`.
- Line and column positions are derived from a line index, not stored redundantly on each node.
- UTF-8 decoding and CSS input preprocessing never change the original byte buffer. Mappings back to byte offsets remain exact for LF, CRLF, CR, form feed, NUL replacement, and multi-byte input.
- A slice operation validates source identity and bounds before returning raw bytes.

### Tokens

- Token kinds and tokenization decisions follow CSS Syntax, including identifiers, functions, at-keywords, hashes and their ID flag, strings/bad strings, URLs/bad URLs, numbers, percentages, dimensions, unicode ranges, delimiters, CDO/CDC, punctuation, whitespace, and EOF.
- Semantic token values are decoded for grammar use, while raw spelling remains available through the source span.
- Numeric tokens preserve representation metadata required to distinguish integer/number behavior and units.
- Comments are retained as lossless trivia even though the standards token stream consumes them. A normalized consumer may filter trivia explicitly.
- Truncated escapes, comments, strings, URLs, UTF-8 sequences, and blocks produce bounded diagnostics or bad tokens; they never index beyond input or panic.

### Lossless syntax boundary

- Component values represent preserved tokens, simple blocks with their opening/closing kinds, and functions with nested component values.
- Whitespace, comments, escapes, and raw spans remain available so unsupported/custom syntax can be preserved without pretending to understand it.
- Typed parsers lower from component values into selectors, declarations, and classified at-rules. They retain raw preludes or values where a stable typed representation does not yet exist.
- The tokenizer and syntax layer must not perform transforms, cascade evaluation, prefixing, minification, or property-specific rewriting.
- The emitter consumes explicit syntax/AST structures and must not invoke an optimizer.

### Diagnostics and recovery

- Tokenization and syntax problems append structured diagnostics with source ID, span, severity, code, and message.
- Parse diagnostics are values and are distinct from allocation, I/O, and internal-invariant errors.
- Recovery must make forward progress. A loop iteration either consumes input, emits a terminal token, or returns an internal error.

## Consequences

Positive consequences:

- Nested delimiters stop being ambiguous byte searches.
- Unknown syntax can round-trip through lossless component values.
- Diagnostics, source maps, parser recovery, and LSP features share the same spans.
- Typed AST work can proceed without teaching the tokenizer property or selector semantics.

Costs and constraints:

- Tokens need both semantic fields and source spans, and some need owned decoded values.
- Retaining trivia and raw source increases memory use compared with destructive byte scanning.
- CSS preprocessing and original-byte spans require careful cursor accounting and line-index tests.
- The old parser must coexist behind an explicit boundary until Milestone 2 migrates the stable path.

## Rejected alternatives

- **Continue delimiter-based parsing with targeted escapes.** Rejected because nesting and recovery are grammar-wide concerns.
- **Build only a typed AST and discard raw syntax.** Rejected because unsupported/custom CSS could not be preserved safely.
- **Store line and column on every token.** Rejected because it duplicates state and makes edits/source-map accounting inconsistent.
- **Normalize the source buffer in place.** Rejected because diagnostics and raw re-emission would lose original byte offsets and spelling.
