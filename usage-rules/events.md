# Events

## Event Binding

- Bind events with `$` prefix: `$click`, `$change`, `$blur`, `$focus`, `$submit`, `$mouse_move`, `$pointer_down`, `$pointer_up`, `$pointer_move`, `$pointer_cancel`, `$select`, `$transition_end`, `$transition_start`, `$transition_run`, `$transition_cancel`.
- Event data is available in the handler's `params` map under the `:event` key.

## Binding Syntax

- **Text (actions only):** `$click="my_action"`
- **Shorthand (actions only):** `$click={:my_action, param_1: 1, param_2: 2}`
- **Longhand (actions and commands):** `$click={action: :my_action, target: "component_cid", params: %{key: val}}`
- **Command trigger:** `$click={command: :my_command, params: %{key: val}}`
- **Delayed action:** `$click={action: :my_action, delay: 1000}`

## Do

- Use text or shorthand syntax for simple action bindings.
- Use longhand syntax when you need to specify a `target`, trigger a command, or add a `delay`.
- Access event-specific data from `params.event` in your action/command handler (e.g. `params.event.value` for `$change`).
- Use `target: "page"`, `target: "layout"`, or a specific CID string to route events to the right component.
- Use meaningful action/command names that describe what they do.

## Don't

- Don't use text or shorthand syntax for commands — commands require longhand syntax with `command:` key.
- Don't use `delay:` with commands — delays are only supported for actions.
- Don't expect `$click` to fire when Ctrl, Cmd, Shift, or middle mouse button is pressed — these are ignored to preserve browser defaults (new tab, text selection, etc.).
- Don't bind events on stateless components without specifying a `target` — events bubble up to the nearest stateful ancestor automatically, but explicit targeting is clearer.
