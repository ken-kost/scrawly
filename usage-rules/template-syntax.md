# Template Syntax

## Syntax Basics

- Templates use the "HOLO" syntax: HTML mixed with Elixir expressions via the `~HOLO` sigil or `.holo` colocated files.
- Access props and state with the `@var` syntax (e.g. `@count`, `@name`).
- Embed Elixir expressions with curly braces: `{@name}`, `{Enum.count(@items)}`.

## Do

- Use `{expression}` for interpolation inside text content and attributes.
- Use `{%if condition}...{/if}` for conditional rendering. Optionally include `{%else}`.
- Use `{%for item <- @items}...{/for}` for iteration — follows Elixir comprehension syntax with pattern matching.
- Use `{%raw}...{/raw}` to output content without HOLO processing (useful for literal curly braces or embedded scripts).
- Escape literal curly braces with backslashes: `\{` and `\}`.
- Pass non-string props (numbers, booleans, expressions) using curly braces: `count={42}`, `active={true}`.
- Use string interpolation within double-quoted attributes: `class="base {@dynamic}"`.
- Rely on automatic HTML escaping for XSS protection — all interpolated values are escaped by default.

## Don't

- Don't use EEx (`<%= %>`) syntax — Hologram uses `{expression}` and `{%block}` syntax instead.
- Don't use `{%elseif}` — it does not exist. Use nested `{%if}` inside `{%else}` or restructure your logic.
- Don't forget that only `nil` and `false` are falsy in `{%if}` conditions (Elixir truthiness rules).
- Don't worry about manually escaping user input in interpolation — it's automatic.
- Don't render an attribute conditionally by wrapping it in `{%if}` — instead return `nil` or `false` from the expression and the attribute will be omitted entirely (e.g. `disabled={@loading?}`).
