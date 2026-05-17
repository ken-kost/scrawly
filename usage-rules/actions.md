# Actions

## Core Concept

- Actions are **client-side** operations that run in the browser.
- They update component state, trigger commands/other actions, navigate pages, and update context.
- Defined as: `def action(name, params, component) do ... end`
- Must return a `%Component{}` struct.

## Do

- Use `put_state/3` to update a single key: `put_state(component, :count, 1)`.
- Use `put_state/2` with a keyword list or map for multiple keys: `put_state(component, count: 1, name: "x")`.
- Use `put_state/3` with a key path for nested updates: `put_state(component, [:user, :name], "John")`.
- Use `put_command/2` or `put_command/3` to trigger a server command from an action.
- Use `put_page/2` or `put_page/3` to navigate: `put_page(component, MyPage, id: 123)`.
- Use `put_context/3` to emit context values to child components.
- Use `put_action/2` or `put_action/3` to chain another action.
- Chain multiple operations with the pipe operator: `component |> put_state(:x, 1) |> put_command(:save)`.
- Access event data via `params.event` and custom params directly from `params`.
- Use `delay:` (in milliseconds) for scheduled actions — useful for animations, auto-hide notifications, debouncing.

## Don't

- Don't perform server-side work (DB queries, file I/O, external API calls) in actions — use commands for that.
- Don't forget to return a `%Component{}` struct from every action.
- Don't mutate state directly — always use `put_state` functions which return a new struct.
- Don't access `server` in actions — the third argument is `component`, not `server`. `server` is only available in commands and `init/3`.
