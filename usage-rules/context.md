# Context

## Core Concept

- Context is for sharing data across components without prop drilling.
- A parent sets context with `put_context/3`; any descendant reads it via `prop :name, :type, from_context: :key`.
- Context flows downward through the component tree from the emitter to all descendants.

## Do

- Use `put_context(component, :key, value)` in actions or `init` to set context values.
- Use namespaced keys to avoid conflicts: `put_context(component, {MyModule, :key}, value)` and `prop :name, :type, from_context: {MyModule, :key}`.
- Use context for truly cross-cutting concerns: authentication state, theme, locale, feature flags.
- Consume context with `prop :local_name, :type, from_context: :context_key` — the prop name and context key can differ.

## Don't

- Don't use context as a replacement for props when data only needs to go to direct children — props are simpler and more explicit.
- Don't store complex objects or functions in context — keep values simple and serializable.
- Don't forget to document which context keys a component expects — implicit dependencies are hard to trace.
- Don't set context from a command — use `put_context` on `component` (in actions or init), not on `server`.
