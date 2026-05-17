# Components

## Module Setup

- Components use `use Hologram.Component`.
- Define props with `prop/2` or `prop/3`: `prop :name, :type` or `prop :name, :type, opts`.
- Available types: `:any`, `:atom`, `:boolean`, `:bitstring`, `:float`, `:function`, `:integer`, `:list`, `:map`, `:pid`, `:port`, `:reference`, `:string`, `:tuple`.

## Stateful vs Stateless

- A component becomes **stateful** when you provide a `cid` attribute: `<MyComp cid="unique_id" />`.
- Stateless components render purely from props. They cannot have actions or commands.
- Stateful components have their own state, can define actions and commands, and are targeted by `cid`.

## Do

- Use `prop :name, :type, default: value` for optional props with defaults.
- Use `prop :user, :map, from_context: :current_user` to source props from Context instead of drilling.
- Use `<slot />` in component templates to accept and render child content.
- Provide a unique, stable `cid` for each stateful component instance.
- Use `init/3` (server-side) when the component starts during SSR page load. Use `init/2` (client-side) when the component is dynamically added to an already-loaded page.
- Return `{component, server}` tuple from `init/3` when modifying both client and server state; return just `component` or just `server` when modifying only one.
- Use `put_state/2` or `put_state/3` inside `init` to set initial state.
- Use `put_action/2` in `init` to chain actions that run after the component mounts.
- Define templates either inline with `def template do ~HOLO"..." end` or in a colocated `.holo` file (same directory, same base name).

## Don't

- Don't forget to assign a `cid` if you need actions, commands, or internal state on a component.
- Don't assume `init/3` and `init/2` both run for the same instance — each instance runs exactly one based on where its lifecycle starts.
- Don't confuse `init/3` params: it receives `(props, component, server)` for components and `(params, component, server)` for pages.
- Don't put business logic directly in templates — use actions and commands.
- Don't place `.holo` files in a different directory than their corresponding `.ex` module file.
- Don't omit both `init/3` and `init/2` if you need initial state — without them, state will be empty.
