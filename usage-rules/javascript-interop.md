# JavaScript Interop

## Setup

- Add `use Hologram.JS` to any client-side module that needs JS interop (alongside `use Hologram.Page` or `use Hologram.Component`).
- Import JS modules with `js_import` at the top of the module.

## Importing

- Default export: `js_import from: "decimal.js", as: :Decimal` (both `:from` and `:as` required).
- Named export: `js_import :multiply, from: "./helpers.mjs"`.
- Named export with alias: `js_import :Chart, from: "chart.js", as: :MyChart`.
- Relative paths (`./`, `../`) resolve relative to the Elixir source file. Bare specifiers resolve as npm packages.
- Each binding name must be unique within a module.

## API

- `JS.call/2` — call a function (imported binding or `window` global): `JS.call(:parseInt, ["42"])`.
- `JS.call/3` — call a method on a receiver: `JS.call(:Math, :round, [3.7])`.
- `JS.new/2` — instantiate a class: `JS.new(:Calculator, [10])`.
- `JS.get/2` — read a property: `JS.get(obj, :value)`.
- `JS.set/3` — write a property (returns receiver for chaining).
- `JS.delete/2` — delete a property (returns receiver for chaining).
- `JS.typeof/1`, `JS.instanceof/2` — type checks.
- `JS.eval/1` — evaluate a single expression.
- `JS.exec/1` / `~JS"""..."""` — execute arbitrary JS code; use `return` to produce a value.
- `JS.dispatch_event/2..4` — dispatch DOM events on elements or globals.
- `Hologram.dispatchAction(name, target, params)` — call Elixir actions from JavaScript.

## Async / Promises

- JS Promises become Elixir `Task`s. Use `Task.await/1` to get the result.
- This applies to `JS.call`, `JS.new`, `JS.get`, `JS.eval`, and `JS.exec` when the JS value is a Promise.

## Type Conversion

- Elixir → JS: integers → number/bigint, floats → number, strings → string, lists → Array, maps → Object, atoms → binding/global/string, anonymous functions → Function.
- JS → Elixir: number → integer/float, string → string, Array → list, plain Object → map (string keys), Promise → Task. Non-convertible values (class instances, symbols, undefined, etc.) become opaque `Hologram.JS.NativeValue` structs.

## Do

- Prefer `JS.call` over `JS.exec`/`JS.eval` — structured calls are easier to maintain.
- Isolate JS interop behind dedicated facade modules rather than calling `JS.call` directly in pages/components.
- Keep `.mjs` files small and single-purpose.
- Use `Task.await/1` for any async JS call.
- Use `Hologram.dispatchAction()` from JS to trigger Elixir actions — it works even before the runtime loads (calls are queued).
- Use `\{` and `\}` or `{%raw}...{/raw}` inside `~HOLO` templates when embedding JS with curly braces.
- Pass Elixir anonymous functions as callbacks to JS functions — they're automatically converted.
- Rely on DOM patching awareness: JS-managed DOM subtrees are preserved across Hologram re-renders.

## Don't

- Don't use JS interop in `init/3` or any server-only code — it only works in action handlers (client-side). On the server, JS calls are no-ops returning `:ok`.
- Don't expect Elixir unit tests to cover JS interop code — use browser-based feature/integration tests instead.
- Don't use `JS.eval`/`JS.exec` for logic that could be expressed with `JS.call` on imported modules.
- Don't assume LiveView hook patterns are the best approach — prefer the low-level API (`JS.call`, `JS.new`, `JS.get`, `JS.set`) for new code. `dispatch_event` exists mainly as a migration convenience.
- Don't declare duplicate binding names within the same module — it raises a compile-time error.
