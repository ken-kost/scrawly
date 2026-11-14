<!-- usage-rules-start -->
<!-- hologram-start -->
## hologram usage
_Full stack isomorphic Elixir web framework that can be used on top of Phoenix._

Hologram is a full-stack isomorphic Elixir web framework. It compiles Elixir to JavaScript for the browser. It is NOT Phoenix LiveView - it has its own template syntax (~HOLO), component model, and state management. Do not use Phoenix/LiveView patterns. Read documentation before attempting to use its features. Do not assume that you have prior knowledge of the framework or its conventions.

For additional details beyond these rules, see deps/hologram/llms-full.txt or https://hologram.page/llms.txt

## Common Pitfalls

- **Never** use Phoenix/LiveView syntax: no `<%= %>`, no `phx-click`, no `<.component>`, no `<:slot>`, no `to_form`, no `<.simple_form>`, no `live_redirect`, no `handle_event`, no `assign`.
- **Never** use HEEx templates. Hologram uses `~HOLO` sigil, not `~H`.
- Actions use `put_state`, not `assign`. State is accessed with `component.state.key`, not `socket.assigns.key`.
- Commands use `server` struct, not `socket`. Return `%Server{}`, not `{:noreply, socket}`.
- Cookie keys are strings (`"my_cookie"`), session keys are atoms or strings (`:locale`). Mixing these up causes errors.
- `init/3` for pages receives URL params, not props. Don't confuse with component `init/3` which receives props.
- Never give a state key the same name as a prop. Templates merge props and state with state winning, so the state key shadows the prop entirely. Copying a prop into a same-named state key in `init` is the usual cause - `init` runs once, so the copy never refreshes and fresh props never reach the template. Use distinct names (an `:initial_count` prop feeding a `:count` state key).
- Never copy a prop into state so an action can read it. Read it from the struct: `component.props.name`. Props follow whatever the parent passes, so an action always reads the current value.
- Stateless components cannot handle events. You need a `cid` to make a component stateful.
- The page cid is `"page"`, the layout cid is `"layout"`. Don't forget these when targeting actions.
- Not all Elixir standard library functions are available client-side yet. Check the Client Runtime reference for coverage.
- The code of a struct type, its protocol implementations and its `__struct__` functions, is not in the runtime or page bundles. The browser loads it as separate chunks when a struct of the type or the type's module atom reaches it: in the state `init/3` sets, in an action a command returns, or in an action the server broadcasts. A page also preloads the chunks of the struct types its own client code names. This covers every struct type, whether or not the app's code names it, so never reference a struct module only to get its code bundled. A module the client builds from a string (`String.to_existing_atom/1`, `Module.concat/2`) loads nothing.
- Reflection functions (`__changeset__/0`, `__schema__/1,2`) called on a named module (`User.__changeset__()`) ship like any other function. Called on a module the code does not name (`mod.__changeset__()`, `apply(mod, :__schema__, [:fields])`), they ship with a page only for the types the page can see: the struct types its client code names, and the ones `init/3`, a command or code that broadcasts an action creates. A call through `apply/3` with a function name known only at runtime is not detected, so a reflection function reached only that way raises `UndefinedFunctionError` on the client - write the function name in the call (`apply(mod, :__schema__, args)`), or call the function on its module somewhere in client-reachable code. Naming the module alone is not enough.
- `try` (with `rescue`/`catch`/`else`/`after`), `raise`, `reraise`, `throw`, and `exit` work client-side, and so does `__STACKTRACE__`. Client errors carry the same messages and stacktraces as server errors, except in environments where `:client_stacktraces` is disabled (the default outside `dev`/`test`), where a trace holds only the frame the error was raised in.
- Realtime: inside `init/3`/commands use `put_subscription`/`put_broadcast` on the `server` struct (deferred until the handler succeeds). The `Hologram.Realtime.*` functions fire immediately and are only for code outside a handler (background jobs, workers).

## Architecture

- Hologram applications are built with two building blocks: **Pages** (route entry points) and **Components** (reusable UI elements).
- **Actions** run on the client (browser). Use them for state updates, navigation, and triggering commands.
- **Commands** run on the server. Use them for database access, API calls, session/cookie management, and other server-side operations.
- State lives in the browser, not on the server. This enables instant UI updates without network round-trips.
- Client-server communication happens automatically over two transports: HTTP/2 request/response for action-command round-trips, and a Server-Sent Events (SSE) stream for server-pushed updates such as broadcast actions. You never configure HTTP endpoints or write boilerplate for either.
- Hologram automatically determines which code runs on the client vs server and compiles the client portions to JavaScript. You don't manually split code.

## Template Syntax

- Hologram templates use the `~HOLO` sigil, not HEEx. **Never** use HEEx syntax (`<%= %>`, `<.component>`, `<:slot>`).
- Access props and state with `@var` syntax: `{@name}`, `{@count}`.
- Reading a var the template doesn't have raises `Hologram.MisuseError`, naming the var and the vars the template has. A declared prop with no default is a var only when the usage passes it, so give it a default if the template reads it.
- Interpolate Elixir expressions with curly braces: `{expression}`. **Not** `<%= expression %>`.
- Component nodes use module names: `<MyComponent prop="value" />`. **Not** `<.my_component>`.
- Tag names can be dynamic: `<{@module} cid="my_id" title="Hello" />` renders a component when the expression yields a component module, `<{@tag} class="heading">` renders an HTML element when it yields a string, anything else raises `ArgumentError`.
- Pair a dynamic tag with a spread when the props are data too: `<{widget.module} ...{widget.props} />`.
- Close a dynamic tag by repeating the opening expression: `<{@module}>content</{@module}>`.
- Page modules are not valid dynamic tags - a page is a root component, renderable only as the root of a page.
- Changing the module rendered under a given `cid` discards the old component's state and initializes the new one.
- A dynamic component's module must appear as a literal in code the compiler can see - a template, a client-reachable function, `init/3`, `command/3`, or code that broadcasts an action. Modules conjured at runtime (`Module.concat/1`, `String.to_existing_atom/1`, values from the database or config) are not bundled and raise on the client.
- Conditional rendering uses `{%if condition}...{/if}` and `{%if condition}...{%else}...{/if}`. **Not** `:if` attribute.
- Iteration uses `{%for item <- @items}...{/for}`. **Not** `:for` attribute.
- Escape curly braces with backslash: `\{literal\}`.
- Raw output (no processing): `{%raw}...{/raw}`.
- When an attribute expression evaluates to `nil` or `false`, the attribute is not rendered at all.
- Spread a map or keyword list as attributes or props with `...{expr}`: `<div ...{@html_attrs}>`, `<MyComponent ...{@props} />`. **Not** HEEx's `{@rest}` - the `...` marker is required.
- Spreads and named attributes resolve by position, last one wins: a literal before a spread is a default, a literal after it is forced.
- On elements, spread keys dasherize (`user_id` renders `user-id`) and nested maps or keyword lists compose dash-joined names (`data: [user_id: 1]` renders `data-user-id="1"`). On components, keys match declared prop names verbatim and values stay raw terms.
- Event bindings (`$`-prefixed keys) can't be spread and raise `ArgumentError` - write them as literal attributes.
- To forward arbitrary attributes through a wrapper component, declare a map prop (`prop :html_attrs, :map`) and spread it onto the inner element: `<button class="fancy" ...{@html_attrs}>`.
- Interpolated expressions in text content and HTML attributes are automatically HTML-escaped to prevent XSS. `<script>` and `<style>` are the exceptions, below.
- Inside a `<script>` element an interpolated expression is escaped as the text of a JavaScript string literal instead, so write it between quotes - `"{@value}"`, `'{@value}'` or `` `{@value}` `` - and the script receives the value exactly as it is; it can never end the script element or the literal. Bare interpolation (`var x = {@value};`) puts the value in code position, where escaping cannot protect it. A value of `alert(1)` runs. A value holding a quote or a `<` becomes a syntax error that stops the script. Write one only for code your own application generates, such as a number or a boolean, and never for anything coming from a user, a request or a database.
- Inside a `<style>` element the same applies with CSS. The stylesheet you write reaches the page as spelled, so a child combinator stays a `>`, and an interpolated expression is escaped as the text of a CSS string literal. Between quotes - `"{@value}"` or `'{@value}'` - the stylesheet gets the value exactly as it is, and no value can end the literal or the element. Escape the braces of a CSS rule as `\{` and `\}`, or wrap the stylesheet in a `{%raw}...{/raw}` block. Bare interpolation (`color: {@value};`) puts the value in code position, where most CSS passes through unchanged, so a generated fragment can be interpolated whole; a newline, a quote or a `<` in it becomes a CSS escape sequence that drops the declaration. As with a script, write one only for values your own application produced.

## Components

- Components use `use Hologram.Component`. **Not** `use Phoenix.Component` or `use Phoenix.LiveComponent`.
- Define props with `prop :name, :type` or `prop :name, :type, default: value`.
- Available prop types: `:any`, `:atom`, `:boolean`, `:bitstring`, `:float`, `:function`, `:integer`, `:list`, `:map`, `:pid`, `:port`, `:reference`, `:string`, `:tuple`.
- Prop options are `default:`, `from_context:`, `required:` and `values:`. Any other option is a compile error, so a typo like `defualt:` fails the build instead of being ignored.
- Source props from context: `prop :user, :map, from_context: :current_user`.
- Require a prop with `prop :size, :atom, required: true`. It can't be combined with `default:` (a prop with a default is never missing), but it can be combined with `from_context:` (the context must then supply it).
- Restrict a prop to a set of values with `prop :size, :atom, values: [:small, :large]`. A `default:` outside its own `values:` list is a compile error.
- A missing required prop is caught at compile time wherever a template writes the component out, and so is any value the compiler can evaluate without running anything: plain text with no interpolation, or a literal - including composites like `{[:small, :large]}` and `{%{size: :small}}`.
- Everything else is checked while rendering and raises `Hologram.PropError`: a `...{@props}` spread, a `<{@module} />` dynamic tag, a `from_context:` prop, an interpolated value (`size="a{@b}"`), and any expression, including one nested inside an otherwise literal value (`{[:small, @other]}`).
- Read a prop in an action with `component.props.name`. Defaults and context-sourced props are in there too, and so is `cid`.
- Stateful components require a `cid` attribute: `<MyComponent cid="my_id" />`. Without `cid`, the component is stateless.
- Each stateful instance is initialized exactly once: `init/3` (props, component, server) runs when its lifecycle starts during server-side page rendering, `init/2` (props, component) when it is dynamically added to an already-loaded page.
- `init/3` can return a `Component` struct, a `Server` struct, or a `{component, server}` tuple.
- Both `init/3` and `init/2` are optional.
- Use `<slot />` for child content. **Not** `<:slot>` or `inner_block`.
- Templates can be defined as a `template/0` function with `~HOLO` sigil, or in a colocated `.holo` file (same name, same directory).
- Colocated `.holo` files contain only markup, without the `~HOLO` sigil wrapper.

## Pages

- Pages use `use Hologram.Page`. **Not** `use Phoenix.LiveView`.
- Every page must define a route: `route "/path"` or `route "/path/:param"`.
- Every page must specify a layout: `layout MyApp.MainLayout` or `layout MyApp.MainLayout, prop: value`.
- Pages are always stateful and always initialized server-side with `init/3` (params, component, server).
- `init/3` receives URL params, not props. Use `param :name, :type` to declare typed route parameters.
- Supported param types: `:atom`, `:float`, `:integer`, `:string`.
- `param` takes no options yet - passing one is a compile error.
- A page's params are its props, so an action reads a URL param with `component.props.name`, the same way a component reads a prop.
- The page's component ID (cid) is always `"page"`. Use `target: "page"` to target actions at it.
- Hologram uses a search tree router, not ordered routing. Static segments always match before parameterized ones. You cannot have two ambiguous parameterized routes at the same level (e.g. `/:username` and `/:post_slug`) - use distinct prefixes instead.

## Layouts

- Layouts are regular components using `use Hologram.Component`. There is no special layout module or macro.
- A layout template **must** include `<Hologram.UI.Runtime />` inside the `<head>` tag.
- A layout template **must** include `<slot />` where page content will be inserted.
- The layout's component ID (cid) is always `"layout"`. Use `target: "layout"` to target actions at it.
- Pass props to layouts via `layout MyApp.MainLayout, prop: value` or via `put_state/2` in the page's `init/3`.

## Events

- Bind events with `$` prefix: `$click`, `$click_outside`, `$change`, `$submit`, `$blur`, `$focus`, `$key_down`, `$key_up`, `$mouse_move`, `$pointer_down`, `$pointer_up`, `$pointer_move`, `$pointer_cancel`, `$resize`, `$scroll`, `$reach_bottom`, `$reach_left`, `$reach_right`, `$reach_top`, `$select`, `$transition_end`, `$transition_start`, `$transition_run`, `$transition_cancel`. **Not** `phx-click` or `phx-change`.
- Text syntax (actions only): `$click="my_action"`.
- Shorthand with params (actions only): `$click={:my_action, key: value}`.
- Longhand (actions or commands): `$click={action: :my_action, target: "cid", params: %{key: value}}`.
- Trigger commands with longhand: `$click={command: :my_command, params: %{key: value}}`.
- Delays (actions only): `$click={action: :my_action, delay: 1000}`.
- A binding that resolves to no operation is disabled: nothing dispatches and the browser's native default proceeds (no `preventDefault`, no `stopPropagation`). Covers a `nil` whole value (`$click={nil}`), a `nil` shorthand name slot (`$click={nil, x: 1}`), and a `nil` longhand `action:`/`command:` key (`$click={action: nil}`). The value is read at event time, so a re-render can enable or disable the binding: `$click={if @editable do :save end}`.
- Conditionals inside template braces need the `do...end` form: `{if @editable, do: :save}` fails the build (template braces are tuple braces, making the call ambiguous), `{if @editable do :save end}` works.
- Valid targets: `"page"`, `"layout"`, or a component's cid string. Default is the containing stateful component.
- Event data is available in `params.event` inside the action/command handler.
- A `$click` binding does not fire on a modified click (`Alt`, `Ctrl`, `Command`, or `Shift` held) - Hologram leaves the event to the browser so the user's shortcut (e.g. open in a new tab) still works.
- `$change` on an input fires on every keystroke (text inputs) or on selection change (checkboxes, radios, selects). On a form element, it fires on field blur.
- Bind global events (not tied to any element, e.g. a global keyboard shortcut) with the `<window>` or `<document>` tag, which attaches to the global `window` or `document`: `<window $key_down.ctrl+k="open_palette" />`. They render nothing and reuse the same `$event` syntax, key filters, and modifiers as element bindings.
- A `<window>` or `<document>` binding follows the same targeting rules as a regular element and accepts only event bindings (any other attribute fails the build). Its listener lives only while the tag renders, so one behind a conditional listens only while that condition holds.
- Use `<window>` for window events (resize, scroll) and `<document>` for document events (tab visibility). Bubbling events like keyboard and pointer reach both, so either tag works for a global shortcut.
- `$click_outside` fires when a click lands anywhere outside the bound element and its descendants - for dismissible UI like dropdowns, popovers, modals, and menus. A click on or inside the element does nothing. Usually rendered only while the element is open (behind a conditional) so it listens for outside clicks just then.
- `$resize` fires when the bound target's size changes (no initial dispatch on first render) - bind it to an element to track that element, or to `<window>` for the browser window. For an element, `params.event` has `border_box_size`, `content_box_size`, and `device_pixel_content_box_size`, each a `%{block_size, inline_size}` map (the device-pixel one is `nil` where unsupported - notably Safari and all iOS browsers). A window resize has an empty payload (the native event provides no size data). It fires rapidly, so pair it with `throttle(ms)` or `debounce(ms)`.
- `$scroll` fires when a scrollable element, or the page, is scrolled - bind it to an element to track that element, or to `<window>` / `<document>` to track the page. `params.event` has `scroll_left` and `scroll_top`. It fires rapidly, so pair it with `throttle(ms)` or `debounce(ms)`.
- `$reach_bottom`, `$reach_left`, `$reach_right`, `$reach_top` fire when a scroll container is scrolled so the matching edge comes into view (the basis for infinite scroll, load-more, pull-to-refresh) - bind them to the scrolling element, one per edge. They carry no `params.event` data (a pure trigger). Each also fires on mount when its edge is already in view, so resolve the binding to `nil` to stop it (e.g. at end-of-data). Append `within(<distance>)` to fire ahead of the edge - a length (`200px`) or a percentage of the container (`50%`), with a default of `100%` (the container's height for top/bottom, its width for left/right). Edges are the visual ones in every layout, `column-reverse`, `row-reverse` and `direction: rtl` containers included.
- Keyboard events (`$key_down`, `$key_up`): `params.event` has `key` (e.g. `"k"`, `"Enter"`, `"ArrowUp"`), `code`, `alt_key`, `ctrl_key`, `meta_key`, `shift_key`, `repeat`. Keyboard events that carry no key (Chromium sends them on autofill, scripts can dispatch them as a plain `Event`) are ignored, so `key` is always a string.
- Filter keyboard events to a key with a dot: `$key_down.enter="submit"`; combine modifiers with `+`: `$key_down.ctrl+enter="send"`. Works on `$key_down` and `$key_up`, case-insensitive, and matches a superset (extra held modifiers do not block it).
- Filter keys: letters/digits as the character (`k`, `7`); modifiers `alt`/`ctrl`/`meta`/`shift` (only when combined with a key); named keys (`arrow_up`, `enter`, `escape`, `space`, `tab`, `f1`-`f12`, ...); symbol keys as alias words (`slash`, `period`, `comma`, `minus`, ...) **not** raw characters.
- Key filters are validated at compile time - a misspelled key like `$key_down.entr` fails the build, **not** a silent runtime no-op.
- For runtime-determined keys, bind bare `$key_down` and match `params.event.key` in the handler.
- The same event can be bound more than once on one element - each `$event` attribute is an independent binding with its own modifiers, timer, and window, and bindings for the same event run in written order. Pairing a plain binding with a debounced one keeps state current on every event while debouncing only the expensive work: `$change="update_query" $change.debounce(300)="run_search"` (the typeahead pattern). Windows can also be layered - `debounce(250)` next to `debounce(1000)` stages cheap and expensive work.
- Debounce high-frequency events by appending `debounce(ms)`, coalescing a burst into one trailing dispatch that carries the last event's data: `$change.debounce(300)="search"`. Bare `debounce` uses a 250ms default. Works on any event, combines with key filters (`$key_down.enter.debounce(300)`), each binding keeps its own timer, and the window is validated at compile time (`$change.debounce(0)` fails the build).
- `debounce` is an event modifier (gates whether and when an event dispatches) - distinct from the `delay` action option (postpones an already-decided dispatch, also settable via `put_action`).
- A pending debounced dispatch resolves early at lifecycle boundaries: it fires immediately when the bound element loses focus (the burst is over) and when the enclosing form is submitted (the submit action observes fresh state, with no trailing dispatch afterward), and it is dropped without firing when the user navigates to another page. Debounce is a pure timing concern - it changes when the dispatch happens, never what the app observes at a boundary.
- Throttle high-frequency events by appending `throttle(ms)`, dispatching at most once per `ms` while events keep firing - the first immediately (leading edge) and the latest of each window on the trailing edge: `$mouse_move.throttle(100)="track"`. Bare `throttle` uses a 100ms default. Works on any event, combines with key filters, each binding keeps its own window, validated at compile time. Cannot be combined with `debounce` on one binding (opposite strategies, fails the build).
- `throttle` caps the dispatch rate during continuous activity, while `debounce` waits for it to stop and dispatches once - throttle for live updates (cursor, drag, scroll), debounce for a final value (search after typing stops).
- Like a pending debounced dispatch, a trailing dispatch held inside an open throttle window is dropped when the user navigates to another page - it never fires into a page it was not meant for.
- Append `once` to fire a binding a single time then stop - one-shot buttons, `$submit.once` against a double-submit, lazy-load on first reach: `$click.once="confirm"`. Works on every event and combines with `debounce`/`throttle` (the single debounced or throttled dispatch fires, then it stops). A spent binding still suppresses the native default and stops propagation per its modifiers - only the action stops dispatching. It is a precise guarantee scoped to the binding's target: an element binding re-arms only when the element is removed and re-added as a fresh DOM node (a re-render keeps it spent), while a `<window>`/`<document>` binding keys on the global target and so fires once for the page without re-arming. For at-most-once over the page lifetime regardless of re-creation, drive it from state instead.
- Append `allow_default` so Hologram does not call `preventDefault` for that binding, letting the browser's native default run while the action still dispatches: `$submit.allow_default="track"`. Hologram calls `preventDefault` by default only on `$submit`, so `allow_default` is meaningful only there - e.g. a form that posts to an external endpoint you also want to track. Composes with key filters, `stop_propagation`, `debounce`, and `throttle`.
- Append `prevent_default` so Hologram calls `preventDefault` for a binding - since `$submit` is the only event prevented by default, this is how you prevent the native default on any other event: `$key_down.enter.prevent_default="send_message"` fires the action without Enter inserting a newline or submitting the form. Only affects cancelable events (no-op on `$change`, `$input`, `$select`, `$scroll`, `$resize`, `$focus`, `$blur`, `$pointer_cancel`, `$transition_*`). It is the mirror of `allow_default`, and the two cannot combine on one binding (fails the build). Composes with key filters (only the matched key is prevented), `stop_propagation`, `debounce`, and `throttle`.
- Append `stop_propagation` to stop the event at the bound element, so ancestor bindings no longer fire while the action still dispatches: `<button $click.stop_propagation="delete_card">` inside a `$click` card fires only the button's action. Hologram never stops propagation on its own. A stopped event also never reaches `$click_outside` or `<window>`/`<document>` bindings (they listen at the document level). Composes with key filters (on keyboard events, propagation stops only for matching keys), `allow_default`, `prevent_default`, `debounce`, and `throttle`.
## Actions

- Actions are client-side. Define with `def action(name, params, component)`. **Not** `handle_event`.
- Actions must return a `%Component{}` struct. Chain operations with `|>`.
- Update state: `put_state(component, :key, value)` or `put_state(component, key: val1, key2: val2)`.
- Nested state update: `put_state(component, [:path, :key], value)`.
- Trigger a command: `put_command(component, :cmd_name)` or `put_command(component, :cmd_name, param: value)`.
- Navigate: `put_page(component, PageModule)` or `put_page(component, PageModule, param: value)`.
- Update context: `put_context(component, :key, value)`.
- Chain another action: `put_action(component, :action_name)` or `put_action(component, :action_name, param: value)`. A chained action with no `delay` runs right after the current one, before the browser paints. The browser paints once the chain has finished, or while one of its actions awaits a task. To update the page between other steps, give the chained action a `delay`.
- Delays are available for actions only (not commands): `put_action(component, name: :my_action, delay: 750)`.
- A component's actions run one at a time, in dispatch order, and each sees the state the previous one left. An action that awaits a `Task` holds back later actions for that component only - other components keep running. If the user has moved to another page by the time an awaiting action finishes, its whole result is dropped. That includes its state update and what it put with `put_action`, `put_command` or `put_page`, even when the new page has a component with the same cid, such as `"page"` or `"layout"`.

## Commands

- Commands are server-side. Define with `def command(name, params, server)`. **Not** `handle_event` or `handle_info`.
- Commands must return a `%Server{}` struct. Chain operations with `|>`.
- Commands are always executed asynchronously.
- Trigger a client action from a command: `put_action(server, :action_name)` or `put_action(server, :action_name, param: value)`.
- The action a command puts runs on the page the command was sent from; it is dropped if the user navigates to another page before it runs. The command's server-side effects (session, cookies, broadcasts) still apply.
- Manage session: `put_session(server, :key, value)`, `get_session(server, :key)`, `delete_session(server, :key)`.
- Manage cookies: `put_cookie(server, "key", value)`, `get_cookie(server, "key")`, `delete_cookie(server, "key")`.
- Commands can be triggered from templates via longhand event syntax or from actions via `put_command/2`/`put_command/3`.

## Navigation

- Use `Hologram.UI.Link` for navigation links: `<Link to={MyPage}>text</Link>`. **Not** `<.link navigate={...}>` or `live_redirect`.
- With params: `<Link to={MyPage, id: 123}>text</Link>`.
- Programmatic navigation from actions: `put_page(component, MyPage)` or `put_page(component, MyPage, id: 123)`.
- Hologram prefetches pages on `$pointer_down` for near-instant transitions.
- Navigating to a page loads it fresh from the server. Back/forward restores a page as the user left it, except after a login or logout: then the page renders fresh and its middleware runs. Jumps to a `#fragment` are left to the browser.

## Forms

- Use standard HTML `<form>`, `<input>`, `<select>`, `<textarea>` elements. **Not** Phoenix form helpers (`to_form`, `<.simple_form>`, `<.input>`).
- **Synchronized inputs** use `value={@state_var}` + `$change="handler"` on the input element. The component state is the single source of truth.
- **Non-synchronized inputs** omit `$change` on the input. Access values via form-level `$change` or `$submit` handlers from `params.event`.
- Text inputs, textareas, and selects sync with the `value` attribute. Checkboxes and radio buttons sync with the `checked` attribute.
- Input-level `$change` on text inputs fires on every keystroke. Form-level `$change` fires on field blur.
- `$submit` event data contains all form field values as a map: `params.event` => `%{field_name: value}`.
- Elixir validation code (including Ecto changesets) runs both client-side and server-side since Hologram runs Elixir in the browser.

## Context

- Context shares data down the component tree without prop drilling. **Not** a global store.
- Set context: `put_context(component, :key, value)` in actions or init functions.
- Namespaced keys to avoid conflicts: `put_context(component, {MyModule, :key}, value)`.
- Access context via props: `prop :user, :map, from_context: :current_user`.
- Context values are available to all descendant components, not siblings or ancestors.
- Prefer props for data passed to direct children. Use context for deeply nested data sharing.

## Middleware

- Middleware is reusable server-side logic that runs before a page renders (before `init/3`) and before commands execute - for authentication, authorization, request enrichment, rate limiting, audit logging. **Not** Phoenix `Plug` or router pipelines.
- Modules use `use Hologram.Middleware`. Three forms: an **inline function** on a page/component, a **leaf** module (does the work), or a **composite** module (combines other middleware).
- Inline: attach with `middleware :name` and define a public `def name(server, opts)` on the same page/component.
- Leaf: a `use Hologram.Middleware` module that defines `def call(server, opts)`.
- Composite: a `use Hologram.Middleware` module that declares a sub-chain with `middleware ...` lines and omits `call/2` (generated for you). It attaches anywhere a leaf can, including inside another composite.
- Attach to a page or component with `middleware SomeModule` or `middleware :some_function`, each with optional keyword opts (`middleware SomeModule, role: :admin`). Declarations run top to bottom.
- Every middleware receives and returns a `%Server{}` struct - the same one `init/3` and commands use. The `Server` helpers (`put_status`, `put_redirect`, `put_session`, `put_stash`, `get_request_header`, ...) are imported unqualified.
- Read the incoming request as `Server` struct fields: `method`, `scheme`, `host`, `port`, `path`, `query`, `raw_query`, `ip`. These are **not** authenticated - `host` is client-supplied and spoofable, so validate it against an allowlist before any security decision and never build security-sensitive URLs (password-reset links, emails) from it.
- Set or clear the authenticated user with `put_user_id(server, user_id)` / `delete_user_id(server)` (persisted to the session) - the canonical login/logout mechanism.
- Stop the chain by setting a status - `put_status(server, :forbidden)`, `put_status(server, 403)`, or `put_redirect(server, MyApp.LoginPage)`. There is no separate `halt`: a non-nil status is the signal, checked after each middleware returns (it does not abort on the spot).
- Response headers set with `put_response_header` / `append_response_header` go out with every response the request ends in - the rendered page, a navigation, a command's reply, or a terminal response - not only with terminal ones. A `content-type` describes the body, so it is allowed only on a response that middleware ends with `put_status`. Anywhere else it raises.
- Pass data downstream with `put_stash(server, :key, value)`, read later with `get_stash` in middleware, `init/3`, or commands.
- Dispatch is flat: page middleware covers the page render and the page's own commands; component middleware covers only that component's commands. A page's middleware does **not** cover its components' commands - attach the gate to the component (or a shared composite) to protect them.
- Compose without a global registry: a base module's `__using__` can inject `middleware` lines into every page/component that uses it (parent first, then child). There is no forced global middleware list - app-wide concerns are plugged into the pages/components that need them.

## Session

- Session is server-side secure storage. Use it in `init/3` and commands only.
- Read: `get_session(server, :key)` or `get_session(server, :key, default)`.
- Write: `put_session(server, :key, value)`.
- Delete: `delete_session(server, :key)`.
- Session keys must be atoms or strings (atoms are converted to strings, so `:locale` and `"locale"` address the same value).
- Sessions can store any Elixir data type (maps, lists, tuples, etc.).
- Record the logged-in user with `put_user_id/2`, not a session key of your own. Hologram knows the user only through it, for the Back/forward check and realtime subscriptions.
- Session data cannot be read by client-side code. Use cookies if you need client-side access.

## Cookies

- Cookies are managed server-side. Use them in `init/3` and commands only.
- Cookie keys must be **strings** (not atoms).
- Read: `get_cookie(server, "key")` or `get_cookie(server, "key", default)`.
- Write: `put_cookie(server, "key", value)` or `put_cookie(server, "key", value, opts)`.
- Delete: `delete_cookie(server, "key")`.
- Cookies can store complex Elixir data structures (maps, lists, etc.) - Hologram handles encoding/decoding automatically.
- Default cookie options: `http_only: true`, `path: "/"`, `same_site: :lax`, `secure: true`.
- Custom options: `http_only`, `path`, `same_site` (`:strict`, `:lax`, `:none`), `secure`, `max_age`, `domain`.
- Use sessions for sensitive data. Use cookies when you need client-side access or specific cookie behavior.

## Realtime

- Realtime lets server-side code push actions to connected clients without polling. A broadcast dispatches an action that runs in the client's `action/3` handler - the trigger just comes from the server. **Not** Phoenix Channels, `phx-join`, or calling `Phoenix.PubSub` directly.
- **In handlers (default):** call `put_subscription`, `delete_subscription`, `put_broadcast`, `put_broadcast_except` on the `server` struct inside `init/3` or `command/3`. They are deferred and transactional - applied only after the handler returns successfully, and discarded if it raises (like `put_session`/`put_cookie`).
- **Outside handlers (escape hatch - background jobs, workers, GenServers, incremental Phoenix adoption):** `Hologram.Realtime.broadcast_action`, `broadcast_action_except`, `subscribe`, `unsubscribe`, `unsubscribe_all`. These fire immediately and do not roll back, and `subscribe`/`unsubscribe` require an explicit cid (e.g. `"page"`). Prefer the in-handler API - reach for these only when there is genuinely no handler.
- Channels are structured values, never topic strings: a bare atom (`:notifications`) or a tuple of an atom tag plus one or more primitives (`{:room, 42}`, `{:doc, "abc-123", "v2"}`).
- Identity channels address recipients - `{:instance, id}` (one tab), `{:session, id}` (one session), `{:user, id}` (one user) - built from `server.instance_id`, `server.session_id`, `server.user_id`.
- Application channels (`:notifications`, `{:room, 42}`) fan a single broadcast out to every component subscribed to them.
- Subscriptions are per-component (cid). `put_subscription` always subscribes the current component - you cannot subscribe on another component's behalf. They are sticky for the page lifetime and auto-cleaned on navigation, so `delete_subscription` is only for removing one mid-page.
- A broadcast names only a channel and an action, never a component. `params` is a keyword list at the call site that arrives as a map in the `action/3` handler. The sender's own instance receives its broadcast too - exclude it with `put_broadcast_except`/`broadcast_action_except` and `{:instance, server.instance_id}`.
- `server.subscriptions` and `server.broadcasts` are readable public fields holding the current component's subscriptions and the broadcasts queued so far.
- Realtime does no authorization - check permissions yourself before any broadcast, subscribe, or unsubscribe.
- Delivery is fire-and-forget and subscription-driven (at-most-once, no acks, replay, or ordering guarantees). Treat broadcasts as live nudges to update already-loaded state and keep authoritative data in your data layer.

## JavaScript Interop

- Add `use Hologram.JS` to any module that needs JS interop. **Not** Phoenix hooks or `phx-hook`.
- Import JS modules: `js_import from: "decimal.js", as: :Decimal` (default export) or `js_import :multiply, from: "./helpers.mjs"` (named export).
- Relative paths (`./`, `../`) resolve relative to the Elixir source file. Bare specifiers resolve as npm packages.
- Call a function: `JS.call(:multiply, [4, 6])`. Call a method: `JS.call(:Math, :round, [3.7])`.
- Instantiate a class: `JS.new(:Calculator, [10])`. Chain with `|>`: `:Calculator |> JS.new([10]) |> JS.call(:add, [5])`.
- Get/set/delete properties: `JS.get(obj, :value)`, `JS.set(obj, :value, 20)`, `JS.delete(obj, :value)`. Inspect values: `JS.typeof(obj)`, `JS.instanceof(obj, :Class)`.
- Evaluate JS: `JS.eval("3 + 4")`. Execute JS: `JS.exec("const x = 2; return x + 3;")`. Inline JS: `~JS"""..."""`.
- Async: JS Promises become Elixir Tasks. Use `Task.await/1` to get the result.
- Dispatch actions from JS: `Hologram.dispatchAction("action_name", "page", {key: value})`. Available immediately - calls before the runtime loads are queued and replayed on mount (safe for inline `<script>`).
- Dispatch DOM events from Elixir: `JS.dispatch_event(target, "my:event", detail: %{value: 42})`.
- Direct DOM manipulation via JS interop is preserved across Hologram re-renders, as long as the container element stays in the template.
- Elixir anonymous functions can be passed as JS callbacks.
- JS interop only works in action handlers (client-side). It is a no-op during server-side rendering.
- Prefer `JS.call` over `JS.exec`/`JS.eval`. Isolate JS interop behind facade modules.

## Configuration

- Hologram settings live under `:hologram` in `config/config.exs`, or in an environment-specific file like `config/prod.exs`. They are read while the client bundles compile, so `config/runtime.exs` is too late and changing one requires a recompile, not just a restart.
- `:client_stacktraces` defaults to `true` in `dev`/`test` and `false` elsewhere. `:client_error_overlay` follows it unless set on its own - set it to `false` to keep the console report without showing an error screen to users.
- Enabling `:client_stacktraces` outside `dev`/`test` puts argument values, source paths and line numbers in front of users, and makes the compiled Elixir in a bundle roughly a third larger over the wire.
- `:max_bundle_size` (bytes) fails the build when a generated bundle grows past it. Unset by default.

## Umbrella Projects

- Only the child app that owns the Phoenix endpoint gets the compiler entry (`compilers: Mix.compilers() ++ [:hologram]`). It also takes the `:hologram` dep and the `Hologram.Router` plug.
- Child apps that only define pages and components take the `:hologram` dep alone. **Never** add the compiler entry to them - their pages are discovered and bundled when the endpoint app compiles.
- Endpoint configuration lives in the umbrella root `config` directory, not in the child app.
- Run `mix holo` from the umbrella root. Started from inside the endpoint app it watches only that app's sources, so changes in sibling apps do not trigger a live reload.
- Add `listeners: [Phoenix.CodeReloader]` to the umbrella root `mix.exs` project config. Mix reads listeners from the project it runs as - the entry Phoenix generates in the endpoint app is not seen when `mix holo` runs from the root.
- npm packages go in an `assets` directory at the umbrella root, not in a child app.
- One Hologram endpoint app per running BEAM instance. If several apps in the umbrella have a configured Phoenix endpoint, Hologram raises a descriptive error.

<!-- hologram-end -->
<!-- ash-start -->
## ash usage
_A declarative, extensible framework for building Elixir applications._

# Rules for working with Ash

## Understanding Ash

Ash is an opinionated, composable framework for building applications in Elixir. It provides a declarative approach to modeling your domain with resources at the center. Read documentation  *before* attempting to use its features. Do not assume that you have prior knowledge of the framework or its conventions.


<!-- ash-end -->
<!-- ash:actions-start -->
## ash:actions usage
# Actions

- Create specific, well-named actions rather than generic ones
- Put all business logic inside action definitions
- Use hooks like `Ash.Changeset.after_action/2`, `Ash.Changeset.before_action/2` to add additional logic
  inside the same transaction.
- Use hooks like `Ash.Changeset.after_transaction/2`, `Ash.Changeset.before_transaction/2` to add additional logic
  outside the transaction.
- Use action arguments for inputs that need validation
- Use preparations to modify queries before execution
- Preparations support `where` clauses for conditional execution
- Use `only_when_valid?` to skip preparations when the query is invalid
- Use changes to modify changesets before execution
- Use validations to validate changesets before execution
- Prefer domain code interfaces to call actions instead of directly building queries/changesets and calling functions in the `Ash` module
- A resource could be *only generic actions*. This can be useful when you are using a resource only to model behavior.

## Error Handling

Functions to call actions, like `Ash.create` and code interfaces like `MyApp.Accounts.register_user` all return ok/error tuples. All have `!` variations, like `Ash.create!` and `MyApp.Accounts.register_user!`. Use the `!` variations when you want to "let it crash", like if looking something up that should definitely exist, or calling an action that should always succeed. Always prefer the raising `!` variation over something like `{:ok, user} = MyApp.Accounts.register_user(...)`.

All Ash code returns errors in the form of `{:error, error_class}`. Ash categorizes errors into four main classes:

1. **Forbidden** (`Ash.Error.Forbidden`) - Occurs when a user attempts an action they don't have permission to perform
2. **Invalid** (`Ash.Error.Invalid`) - Occurs when input data doesn't meet validation requirements
3. **Framework** (`Ash.Error.Framework`) - Occurs when there's an issue with how Ash is being used
4. **Unknown** (`Ash.Error.Unknown`) - Occurs for unexpected errors that don't fit the other categories

These error classes help you catch and handle errors at an appropriate level of granularity. An error class will always be the "worst" (highest in the above list) error class from above. Each error class can contain multiple underlying errors, accessible via the `errors` field on the exception.

## Using Validations

Validations ensure that data meets your business requirements before it gets processed by an action. Unlike changes, validations cannot modify the changeset - they can only validate it or add errors.

Validations work on both changesets and queries. Built-in validations that support queries include:
- `action_is`, `argument_does_not_equal`, `argument_equals`, `argument_in`
- `compare`, `confirm`, `match`, `negate`, `one_of`, `present`, `string_length`
- Custom validations that implement the `supports/1` callback

Common validation patterns:

```elixir
# Built-in validations with custom messages
validate compare(:age, greater_than_or_equal_to: 18) do
  message "You must be at least 18 years old"
end
validate match(:email, "@")
validate one_of(:status, [:active, :inactive, :pending])

# Conditional validations with where clauses
validate present(:phone_number) do
  where present(:contact_method) and eq(:contact_method, "phone")
end

# only_when_valid? - skip validation if prior validations failed
validate expensive_validation() do
  only_when_valid? true
end

# Action-specific vs global validations
actions do
  create :sign_up do
    validate present([:email, :password])  # Only for this action
  end
  
  read :search do
    argument :email, :string
    validate match(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/)  # Validates query arguments
  end
end

validations do
  validate present([:title, :body]), on: [:create, :update]  # Multiple actions
end
```

- Create **custom validation modules** for complex validation logic:
  ```elixir
  defmodule MyApp.Validations.UniqueUsername do
    use Ash.Resource.Validation

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def validate(changeset, _opts, _context) do
      # Validation logic here
      # Return :ok or {:error, message}
    end
  end

  # Usage in resource:
  validate {MyApp.Validations.UniqueUsername, []}
  ```

- Make validations **atomic** when possible to ensure they work correctly with direct database operations by implementing the `atomic/3` callback in custom validation modules.

  ```elixir
  defmodule MyApp.Validations.IsEven do
    # transform and validate opts

    use Ash.Resource.Validation

    @impl true
    def init(opts) do
      if is_atom(opts[:attribute]) do
        {:ok, opts}
      else
        {:error, "attribute must be an atom!"}
      end
    end

    @impl true
    # This is optional, but useful to have in addition to validation
    # so you get early feedback for validations that can otherwise
    # only run in the datalayer
    def validate(changeset, opts, _context) do
      value = Ash.Changeset.get_attribute(changeset, opts[:attribute])

      if is_nil(value) || (is_number(value) && rem(value, 2) == 0) do
        :ok
      else
        {:error, field: opts[:attribute], message: "must be an even number"}
      end
    end

    @impl true
    def atomic(changeset, opts, context) do
      {:atomic,
        # the list of attributes that are involved in the validation
        [opts[:attribute]],
        # the condition that should cause the error
        # here we refer to the new value or the current value
        expr(rem(^atomic_ref(opts[:attribute]), 2) != 0),
        # the error expression
        expr(
          error(^InvalidAttribute, %{
            field: ^opts[:attribute],
            # the value that caused the error
            value: ^atomic_ref(opts[:attribute]),
            # the message to display
            message: ^(context.message || "%{field} must be an even number"),
            vars: %{field: ^opts[:attribute]}
          })
        )
      }
    end
  end
  ```

- **Avoid redundant validations** - Don't add validations that duplicate attribute constraints:
  ```elixir
  # WRONG - redundant validation
  attribute :name, :string do
    allow_nil? false
    constraints min_length: 1
  end

  validate present(:name) do  # Redundant! allow_nil? false already handles this
    message "Name is required"
  end

  validate attribute_does_not_equal(:name, "") do  # Redundant! min_length: 1 already handles this
    message "Name cannot be empty"
  end

  # CORRECT - let attribute constraints handle basic validation
  attribute :name, :string do
    allow_nil? false
    constraints min_length: 1
  end
  ```

## Using Preparations

Preparations modify queries before they're executed. They are used to add filters, sorts, or other query modifications based on the query context.

Common preparation patterns:

```elixir
# Built-in preparations
prepare build(sort: [created_at: :desc])
prepare build(filter: [active: true])

# Conditional preparations with where clauses
prepare build(filter: [visible: true]) do
  where argument_equals(:include_hidden, false)
end

# only_when_valid? - skip preparation if prior validations failed
prepare expensive_preparation() do
  only_when_valid? true
end

# Action-specific vs global preparations
actions do
  read :recent do
    prepare build(sort: [created_at: :desc], limit: 10)
  end
end

preparations do
  prepare build(filter: [deleted: false]), on: [:read, :update]
end
```

## Using Changes

Changes allow you to modify the changeset before it gets processed by an action. Unlike validations, changes can manipulate attribute values, add attributes, or perform other data transformations.

Common change patterns:

```elixir
# Built-in changes with conditions
change set_attribute(:status, "pending")
change relate_actor(:creator) do
  where present(:actor)
end
change atomic_update(:counter, expr(^counter + 1))

# Action-specific vs global changes
actions do
  create :sign_up do
    change set_attribute(:joined_at, expr(now()))  # Only for this action
  end
end

changes do
  change set_attribute(:updated_at, expr(now())), on: :update  # Multiple actions
  change manage_relationship(:items, type: :append), on: [:create, :update]
end
```

- Create **custom change modules** for reusable transformation logic:
  ```elixir
  defmodule MyApp.Changes.SlugifyTitle do
    use Ash.Resource.Change

    def change(changeset, _opts, _context) do
      title = Ash.Changeset.get_attribute(changeset, :title)

      if title do
        slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
        Ash.Changeset.change_attribute(changeset, :slug, slug)
      else
        changeset
      end
    end
  end

  # Usage in resource:
  change {MyApp.Changes.SlugifyTitle, []}
  ```

- Create a **change module with lifecycle hooks** to handle complex multi-step operations:

  ```elixir
  defmodule MyApp.Changes.ProcessOrder do
    use Ash.Resource.Change

    def change(changeset, _opts, context) do
      changeset
      |> Ash.Changeset.before_transaction(fn changeset ->
        # Runs before the transaction starts
        # Use for external API calls, logging, etc.
        MyApp.ExternalService.reserve_inventory(changeset, scope: context)
        changeset
      end)
      |> Ash.Changeset.before_action(fn changeset ->
        # Runs inside the transaction before the main action
        # Use for related database changes in the same transaction
        Ash.Changeset.change_attribute(changeset, :processed_at, DateTime.utc_now())
      end)
      |> Ash.Changeset.after_action(fn changeset, result ->
        # Runs inside the transaction after the main action, only on success
        # Use for related database changes that depend on the result
        MyApp.Inventory.update_stock_levels(result, scope: context)
        {changeset, result}
      end)
      |> Ash.Changeset.after_transaction(fn changeset,
        {:ok, result} ->
          # Runs after the transaction completes (success or failure)
          # Use for notifications, external systems, etc.
          MyApp.Mailer.send_order_confirmation(result, scope: context)
          {changeset, result}

        {:error, error} ->
          # Runs after the transaction completes (success or failure)
          # Use for notifications, external systems, etc.
          MyApp.Mailer.send_order_issue_notice(result, scope: context)
          {:error, error}
      end)
    end
  end

  # Usage in resource:
  change {MyApp.Changes.ProcessOrder, []}
  ```

## Atomic Changes

Atomic changes execute directly in the database as part of the update query, without requiring the record to be loaded first. This provides better performance and correct behavior under concurrent updates.

**Why atomic matters:**
- Avoids race conditions (e.g., incrementing a counter)
- Better performance (no round-trip to load the record)
- Required for bulk operations to work efficiently

**Built-in atomic changes:**
```elixir
# Increment a counter atomically
change atomic_update(:view_count, expr(view_count + 1))

# Set a value using an expression
change set_attribute(:updated_at, expr(now()))
```

**Making custom changes atomic:**
Implement the `atomic/3` callback to support atomic execution:

```elixir
defmodule MyApp.Changes.IncrementVersion do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Fallback for non-atomic execution
    current = Ash.Changeset.get_attribute(changeset, :version) || 0
    Ash.Changeset.change_attribute(changeset, :version, current + 1)
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    # Atomic implementation - runs in the database
    {:atomic, %{version: expr(coalesce(version, 0) + 1)}}
  end
end
```

## Using `require_atomic? false`

By default, update and destroy actions require all changes and validations to support atomic execution. If they don't, the action will raise an error.

**IMPORTANT:** When you see `require_atomic? false` on an action, carefully consider whether it is truly necessary. This option should be used sparingly.

**When `require_atomic? false` is needed:**
- The action has `before_action` or `around_action` hooks that need to read or modify the record
- A change reads the current record state (e.g., `Ash.Changeset.get_data/2`) and cannot be rewritten atomically
- Complex validations that cannot be expressed as database expressions

**When `require_atomic? false` is NOT needed:**
- Simple attribute transformations (these can usually be made atomic)
- Setting timestamps or default values (use `expr(now())` instead)
- Incrementing counters (use `atomic_update/2`)
- After-action hooks (these don't prevent atomic execution)
- After-transaction hooks (these don't prevent atomic execution)

```elixir
actions do
  update :update do
    # AVOID unless truly necessary
    require_atomic? false
  end

  update :increment_views do
    # GOOD - fully atomic, no need to disable
    change atomic_update(:view_count, expr(view_count + 1))
  end
end
```

If you find yourself adding `require_atomic? false`, first check if your changes and validations can be rewritten with `atomic/3` callbacks. Only disable atomic requirements when the action genuinely needs to read or manipulate the record in hooks.

## Custom Modules vs. Anonymous Functions

Prefer to put code in its own module and refer to that in changes, preparations, validations etc.

For example, prefer this:

```elixir
defmodule MyApp.MyDomain.MyResource.Changes.SlugifyName do
  use Ash.Resource.Change

  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset, _ ->
      slug = MyApp.Slug.get()
      Ash.Changeset.force_change_attribute(changeset, :slug, slug)
    end)
  end
end

change MyApp.MyDomain.MyResource.Changes.SlugifyName
```

## Action Types

- **Read**: For retrieving records
- **Create**: For creating records
- **Update**: For changing records
- **Destroy**: For removing records
- **Generic**: For custom operations that don't fit the other types



<!-- ash:actions-end -->
<!-- ash:aggregates-start -->
## ash:aggregates usage
# Aggregates

Aggregates allow you to retrieve summary information over groups of related data, like counts, sums, or averages. Define aggregates in the `aggregates` block of a resource.

Aggregates can work over relationships or directly over unrelated resources:

```elixir
aggregates do
  # Related aggregates - use relationship path
  count :published_post_count, :posts do
    filter expr(published == true)
  end

  sum :total_sales, :orders, :amount

  exists :is_admin, :roles do
    filter expr(name == "admin")
  end

  # Unrelated aggregates - use resource module directly
  count :matching_profiles_count, Profile do
    filter expr(name == parent(name))
  end
  
  sum :total_report_score, Report, :score do
    filter expr(author_name == parent(name))
  end
  
  exists :has_reports, Report do
    filter expr(author_name == parent(name))
  end
end
```

For unrelated aggregates, use `parent/1` to reference fields from the source resource.

## Aggregate Types

- **count**: Counts related items meeting criteria
- **sum**: Sums a field across related items
- **exists**: Returns boolean indicating if matching related items exist (also supports unrelated resources)
- **first**: Gets the first related value matching criteria
- **list**: Lists the related values for a specific field
- **max**: Gets the maximum value of a field
- **min**: Gets the minimum value of a field
- **avg**: Gets the average value of a field

## Using Aggregates

```elixir
# Using code interface options (preferred)
users = MyDomain.list_users!(
  load: [:published_post_count, :total_sales],
  query: [
    filter: [published_post_count: [greater_than: 5]],
    sort: [published_post_count: :desc]
  ]
)

# Manual query building (for complex cases)
User |> Ash.Query.filter(published_post_count > 5) |> Ash.read!()

# Loading on existing records
Ash.load!(users, :published_post_count)
```

### Join Filters

For complex aggregates involving multiple relationships, use join filters:

```elixir
aggregates do
  sum :redeemed_deal_amount, [:redeems, :deal], :amount do
    # Filter on the aggregate as a whole
    filter expr(redeems.redeemed == true)

    # Apply filters to specific relationship steps
    join_filter :redeems, expr(redeemed == true)
    join_filter [:redeems, :deal], expr(active == parent(require_active))
  end
end
```

## Inline Aggregates

Use aggregates inline within expressions:

```elixir
# Related inline aggregates
calculate :grade_percentage, :decimal, expr(
  count(answers, query: [filter: expr(correct == true)]) * 100 /
  count(answers)
)

# Unrelated inline aggregates
calculate :profile_count, :integer, expr(
  count(Profile, filter: expr(name == parent(name)))
)

calculate :stats, :map, expr(%{
  profiles: count(Profile, filter: expr(active == true)),
  reports: count(Report, filter: expr(author_name == parent(name))),
  has_active_profile: exists(Profile, active == true and name == parent(name))
})
```


<!-- ash:aggregates-end -->
<!-- ash:authorization-start -->
## ash:authorization usage
# Authorization

- When performing administrative actions, you can bypass authorization with `authorize?: false`
- To run actions as a particular user, look that user up and pass it as the `actor` option
- Always set the actor on the query/changeset/input, not when calling the action
- Use policies to define authorization rules

```elixir
# Good
Post
|> Ash.Query.for_read(:read, %{}, actor: current_user)
|> Ash.read!()

# BAD, DO NOT DO THIS
Post
|> Ash.Query.for_read(:read, %{})
|> Ash.read!(actor: current_user)
```

## Policies

To use policies, add the `Ash.Policy.Authorizer` to your resource:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    authorizers: [Ash.Policy.Authorizer]

  # Rest of resource definition...
end
```

## Policy Basics

Policies determine what actions on a resource are permitted for a given actor. Define policies in the `policies` block:

```elixir
policies do
  # A simple policy that applies to all read actions
  policy action_type(:read) do
    # Authorize if record is public
    authorize_if expr(public == true)

    # Authorize if actor is the owner
    authorize_if relates_to_actor_via(:owner)
  end

  # A policy for create actions
  policy action_type(:create) do
    # Only allow active users to create records
    forbid_unless actor_attribute_equals(:active, true)

    # Ensure the record being created relates to the actor
    authorize_if relating_to_actor(:owner)
  end
end
```

## Policy Evaluation Flow

Policies evaluate from top to bottom with the following logic:

1. All policies that apply to an action must pass for the action to be allowed
2. Within each policy, checks evaluate from top to bottom
3. The first check that produces a decision determines the policy result
4. If no check produces a decision, the policy defaults to forbidden

## IMPORTANT: Policy Check Logic

**the first check that yields a result determines the policy outcome**

```elixir
# WRONG - This is OR logic, not AND logic!
policy action_type(:update) do
  authorize_if actor_attribute_equals(:admin?, true)    # If this passes, policy passes
  authorize_if relates_to_actor_via(:owner)           # Only checked if first fails
end
```

To require BOTH conditions in that example, you would use `forbid_unless` for the first condition:

```elixir
# CORRECT - This requires BOTH conditions
policy action_type(:update) do
  forbid_unless actor_attribute_equals(:admin?, true)  # Must be admin
  authorize_if relates_to_actor_via(:owner)           # AND must be owner
end
```

Alternative patterns for AND logic:
- Use multiple separate policies (each must pass independently)
- Use a single complex expression with `expr(condition1 and condition2)`
- Use `forbid_unless` for required conditions, then `authorize_if` for the final check

## Bypass Policies

Use bypass policies to allow certain actors to bypass other policy restrictions. This should be used almost exclusively for admin bypasses.

```elixir
policies do
  # Bypass policy for admins - if this passes, other policies don't need to pass
  bypass actor_attribute_equals(:admin, true) do
    authorize_if always()
  end

  # Regular policies follow...
  policy action_type(:read) do
    # ...
  end
end
```

## Field Policies

Field policies control access to specific fields (attributes, calculations, aggregates):

```elixir
field_policies do
  # Only supervisors can see the salary field
  field_policy :salary do
    authorize_if actor_attribute_equals(:role, :supervisor)
  end

  # Allow access to all other fields
  field_policy :* do
    authorize_if always()
  end
end
```

## Policy Checks

There are two main types of checks used in policies:

1. **Simple checks** - Return true/false answers (e.g., "is the actor an admin?")
2. **Filter checks** - Return filters to apply to data (e.g., "only show records owned by the actor")

You can use built-in checks or create custom ones:

```elixir
# Built-in checks
authorize_if actor_attribute_equals(:role, :admin)
authorize_if relates_to_actor_via(:owner)
authorize_if expr(public == true)

# Custom check module
authorize_if MyApp.Checks.ActorHasPermission
```

### Custom Policy Checks

Create custom checks by implementing `Ash.Policy.SimpleCheck` or `Ash.Policy.FilterCheck`:

```elixir
# Simple check - returns true/false
defmodule MyApp.Checks.ActorHasRole do
  use Ash.Policy.SimpleCheck

  def match?(%{role: actor_role}, _context, opts) do
    actor_role == (opts[:role] || :admin)
  end
  def match?(_, _, _), do: false
end

# Filter check - returns query filter
defmodule MyApp.Checks.VisibleToUserLevel do
  use Ash.Policy.FilterCheck

  def filter(actor, _authorizer, _opts) do
    expr(visibility_level <= ^actor.user_level)
  end
end

# Usage
policy action_type(:read) do
  authorize_if {MyApp.Checks.ActorHasRole, role: :manager}
  authorize_if MyApp.Checks.VisibleToUserLevel
end
```


<!-- ash:authorization-end -->
<!-- ash:calculations-start -->
## ash:calculations usage
# Calculations

Calculations allow you to define derived values based on a resource's attributes or related data. Define calculations in the `calculations` block of a resource:

```elixir
calculations do
  # Simple expression calculation
  calculate :full_name, :string, expr(first_name <> " " <> last_name)

  # Expression with conditions
  calculate :status_label, :string, expr(
    cond do
      status == :active -> "Active"
      status == :pending -> "Pending Review"
      true -> "Inactive"
    end
  )

  # Using module calculations for more complex logic
  calculate :risk_score, :integer, {MyApp.Calculations.RiskScore, min: 0, max: 100}
end
```

## Expression Calculations

Expression calculations use Ash expressions and can be pushed down to the data layer when possible:

```elixir
calculations do
  # Simple string concatenation
  calculate :full_name, :string, expr(first_name <> " " <> last_name)

  # Math operations
  calculate :total_with_tax, :decimal, expr(amount * (1 + tax_rate))

  # Date manipulation
  calculate :days_since_created, :integer, expr(
    date_diff(^now(), inserted_at, :day)
  )
end
```

## Expressions

In order to use expressions outside of resources, changes, preparations etc. you will need to use `Ash.Expr`.

It provides both `expr/1` and template helpers like `actor/1` and `arg/1`.

For example:

```elixir
import Ash.Expr

Author
|> Ash.Query.aggregate(:count_of_my_favorited_posts, :count, [:posts], query: [
  filter: expr(favorited_by(user_id: ^actor(:id)))
])
```

See the expressions guide for more information on what is available in expresisons and
how to use them.

## Module Calculations

For complex calculations, create a module that implements `Ash.Resource.Calculation`:

```elixir
defmodule MyApp.Calculations.FullName do
  use Ash.Resource.Calculation

  # Validate and transform options
  @impl true
  def init(opts) do
    {:ok, Map.put_new(opts, :separator, " ")}
  end

  # Specify what data needs to be loaded
  @impl true
  def load(_query, _opts, _context) do
    [:first_name, :last_name]
  end

  # Implement the calculation logic
  @impl true
  def calculate(records, opts, _context) do
    Enum.map(records, fn record ->
      [record.first_name, record.last_name]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(opts.separator)
    end)
  end
end

# Usage in a resource
calculations do
  calculate :full_name, :string, {MyApp.Calculations.FullName, separator: ", "}
end
```

## Calculations with Arguments

You can define calculations that accept arguments:

```elixir
calculations do
  calculate :full_name, :string, expr(first_name <> ^arg(:separator) <> last_name) do
    argument :separator, :string do
      allow_nil? false
      default " "
      constraints [allow_empty?: true, trim?: false]
    end
  end
end
```

## Using Calculations

```elixir
# Using code interface options (preferred)
users = MyDomain.list_users!(load: [full_name: [separator: ", "]])

# Filtering and sorting
users = MyDomain.list_users!(
  query: [
    filter: [full_name: [separator: " ", value: "John Doe"]],
    sort: [full_name: {[separator: " "], :asc}]
  ]
)

# Manual query building (for complex cases)
User |> Ash.Query.load(full_name: [separator: ", "]) |> Ash.read!()

# Loading on existing records
Ash.load!(users, :full_name)
```

### Code Interface for Calculations

Define calculation functions on your domain for standalone use:

```elixir
# In your domain
resource User do
  define_calculation :full_name, args: [:first_name, :last_name, {:optional, :separator}]
end

# Then call it directly
MyDomain.full_name("John", "Doe", ", ")  # Returns "John, Doe"
```


<!-- ash:calculations-end -->
<!-- ash:code_interfaces-start -->
## ash:code_interfaces usage
# Code Interfaces

Use code interfaces on domains to define the contract for calling into Ash resources. See the [Code interface guide for more](https://hexdocs.pm/ash/code-interfaces.html).

Define code interfaces on the domain, like this:

```elixir
resource ResourceName do
  define :fun_name, action: :action_name
end
```

For more complex interfaces with custom transformations:

```elixir
define :custom_action do
  action :action_name
  args [:arg1, :arg2]

  custom_input :arg1, MyType do
    transform do
      to :target_field
      using &MyModule.transform_function/1
    end
  end
end
```

Prefer using the primary read action for "get" style code interfaces, and using `get_by` when the field you are looking up by is the primary key or has an `identity` on the resource.

```elixir
resource ResourceName do
  define :get_thing, action: :read, get_by: [:id]
end
```

**Avoid direct Ash calls in web modules** - Don't use `Ash.get!/2` and `Ash.load!/2` directly in LiveViews/Controllers, similar to avoiding `Repo.get/2` outside context modules:

You can also pass additional inputs in to code interfaces before the options:

```elixir
resource ResourceName do
  define :create, action: :action_name, args: [:field1]
end
```

```elixir
Domain.create!(field1_value, %{field2: field2_value}, actor: current_user)
```

You should generally prefer using this map of extra inputs over defining optional arguments.

```elixir
# BAD - in LiveView/Controller
group = MyApp.Resource |> Ash.get!(id) |> Ash.load!(rel: [:nested])

# GOOD - use code interface with get_by
resource DashboardGroup do
  define :get_dashboard_group_by_id, action: :read, get_by: [:id]
end

# Then call:
MyApp.Domain.get_dashboard_group_by_id!(id, load: [rel: [:nested]])
```

**Code interface options** - Prefer passing options directly to code interface functions rather than building queries manually:

```elixir
# PREFERRED - Use the query option for filter, sort, limit, etc.
# the query option is passed to `Ash.Query.build/2`
posts = MyApp.Blog.list_posts!(
  query: [
    filter: [status: :published],
    sort: [published_at: :desc],
    limit: 10
  ],
  load: [author: :profile, comments: [:author]]
)

# All query-related options go in the query parameter
users = MyApp.Accounts.list_users!(
  query: [filter: [active: true], sort: [created_at: :desc]],
  load: [:profile]
)

# AVOID - Verbose manual query building
query = MyApp.Post |> Ash.Query.filter(...) |> Ash.Query.load(...)
posts = Ash.read!(query)
```

Supported options: `load:`, `query:` (which accepts `filter:`, `sort:`, `limit:`, `offset:`, etc.), `page:`, `stream?:`

**Using Scopes in LiveViews** - When using `Ash.Scope`, the scope will typically be assigned to `scope` in LiveViews and used like so:

```elixir
# In your LiveView
MyApp.Blog.create_post!("new post", scope: socket.assigns.scope)
```

Inside action hooks and callbacks, use the provided `context` parameter as your scope instead:

```elixir
|> Ash.Changeset.before_transaction(fn changeset, context ->
  MyApp.ExternalService.reserve_inventory(changeset, scope: context)
  changeset
end)
```

## Authorization Functions

For each action defined in a code interface, Ash automatically generates corresponding authorization check functions:

- `can_action_name?(actor, params \\ %{}, opts \\ [])` - Returns `true`/`false` for authorization checks
- `can_action_name(actor, params \\ %{}, opts \\ [])` - Returns `{:ok, true/false}` or `{:error, reason}`

Example usage:
```elixir
# Check if user can create a post
if MyApp.Blog.can_create_post?(current_user) do
  # Show create button
end

# Check if user can update a specific post
if MyApp.Blog.can_update_post?(current_user, post) do
  # Show edit button
end

# Check if user can destroy a specific comment
if MyApp.Blog.can_destroy_comment?(current_user, comment) do
  # Show delete button
end
```

These functions are particularly useful for conditional rendering of UI elements based on user permissions.


<!-- ash:code_interfaces-end -->
<!-- ash:code_structure-start -->
## ash:code_structure usage
# Code Structure & Organization

- Organize code around domains and resources
- Each resource should be focused and well-named
- Create domain-specific actions rather than generic CRUD operations
- Put business logic inside actions rather than in external modules
- Use resources to model your domain entities

<!-- ash:code_structure-end -->
<!-- ash:data_layers-start -->
## ash:data_layers usage
# Data Layers

Data layers determine how resources are stored and retrieved. Examples of data layers:

- **Postgres**: For storing resources in PostgreSQL (via `AshPostgres`)
- **ETS**: For in-memory storage (`Ash.DataLayer.Ets`)
- **Mnesia**: For distributed storage (`Ash.DataLayer.Mnesia`)
- **Embedded**: For resources embedded in other resources (`data_layer: :embedded`) (typically JSON under the hood)
- **Ash.DataLayer.Simple**: For resources that aren't persisted at all. Leave off the data layer, as this is the default.

Specify a data layer when defining a resource:

```elixir
defmodule MyApp.Post do
  use Ash.Resource,
    domain: MyApp.Blog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "posts"
    repo MyApp.Repo
  end

  # ... attributes, relationships, etc.
end
```

For embedded resources:

```elixir
defmodule MyApp.Address do
  use Ash.Resource,
    data_layer: :embedded

  attributes do
    attribute :street, :string
    attribute :city, :string
    attribute :state, :string
    attribute :zip, :string
  end
end
```

Each data layer has its own configuration options and capabilities. Refer to the rules & documentation of the specific data layer package for more details.


<!-- ash:data_layers-end -->
<!-- ash:exist_expressions-start -->
## ash:exist_expressions usage
# Exists Expressions

Use `exists/2` to check for the existence of records, either through relationships or unrelated resources:

### Related Exists

```elixir
# Check if user has any admin roles
Ash.Query.filter(User, exists(roles, name == "admin"))

# Check if post has comments with high scores
Ash.Query.filter(Post, exists(comments, score > 50))
```

### Unrelated Exists

```elixir
# Check if any profile exists with the same name
Ash.Query.filter(User, exists(Profile, name == parent(name)))

# Check if user has any reports
Ash.Query.filter(User, exists(Report, author_name == parent(name)))

# Complex existence checks
Ash.Query.filter(User, 
  active == true and 
  exists(Profile, active == true and name == parent(name))
)
```

Unrelated exists expressions automatically apply authorization using the target resource's primary read action. Use `parent/1` to reference fields from the source resource.

<!-- ash:exist_expressions-end -->
<!-- ash:generating_code-start -->
## ash:generating_code usage
# Generating Code

Use `mix ash.gen.*` tasks as a basis for code generation when possible. Check the task docs with `mix help <task>`.
Be sure to use `--yes` to bypass confirmation prompts. Use `--yes --dry-run` to preview the changes.


<!-- ash:generating_code-end -->
<!-- ash:migrations-start -->
## ash:migrations usage
# Migrations and Schema Changes

After creating or modifying Ash code, run `mix ash.codegen <short_name_describing_changes>` to ensure any required additional changes are made (like migrations are generated). The name of the migration should be lower_snake_case. In a longer running dev session it's usually better to use `mix ash.codegen --dev` as you go and at the end run the final codegen with a sensible name describing all the changes made in the session.


<!-- ash:migrations-end -->
<!-- ash:query_filter-start -->
## ash:query_filter usage
# Ash.Query.filter is a macro

**Important**: You must `require Ash.Query` if you want to use `Ash.Query.filter/2`, as it is a macro.

If you see errors like the following:

```
Ash.Query.filter(MyResource, id == ^id)
error: misplaced operator ^id

The pin operator ^ is supported only inside matches or inside custom macros...
```

```
iex(3)> Ash.Query.filter(MyResource, something == true)
error: undefined variable "something"
└─ iex:3
```

You are very likely missing a `require Ash.Query`

## Common Query Operations

- **Filter**: `Ash.Query.filter(query, field == value)`
- **Sort**: `Ash.Query.sort(query, field: :asc)`
- **Load relationships**: `Ash.Query.load(query, [:author, :comments])`
- **Limit**: `Ash.Query.limit(query, 10)`
- **Offset**: `Ash.Query.offset(query, 20)`


<!-- ash:query_filter-end -->
<!-- ash:querying_data-start -->
## ash:querying_data usage
# Querying Data

Use `Ash.Query` to build queries for reading data from your resources. The query module provides a declarative way to filter, sort, and load data.


<!-- ash:querying_data-end -->
<!-- ash:relationships-start -->
## ash:relationships usage
# Relationships

Relationships describe connections between resources and are a core component of Ash. Define relationships in the `relationships` block of a resource.

## Best Practices for Relationships

- Be descriptive with relationship names (e.g., use `:authored_posts` instead of just `:posts`)
- Configure foreign key constraints in your data layer if they have them (see `references` in AshPostgres)
- Always choose the appropriate relationship type based on your domain model

### Relationship Types

- For Polymorphic relationships, you can model them using `Ash.Type.Union`; see the “Polymorphic Relationships” guide for more information.

```elixir
relationships do
  # belongs_to - adds foreign key to source resource
  belongs_to :owner, MyApp.User do
    allow_nil? false
    attribute_type :integer  # defaults to :uuid
  end

  # has_one - foreign key on destination resource
  has_one :profile, MyApp.Profile

  # has_many - foreign key on destination resource, returns list
  has_many :posts, MyApp.Post do
    filter expr(published == true)
    sort published_at: :desc
  end

  # many_to_many - requires join resource
  many_to_many :tags, MyApp.Tag do
    through MyApp.PostTag
    source_attribute_on_join_resource :post_id
    destination_attribute_on_join_resource :tag_id
  end
end
```

The join resource must be defined separately:

```elixir
defmodule MyApp.PostTag do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer

  attributes do
    uuid_primary_key :id
    # Add additional attributes if you need metadata on the relationship
    attribute :added_at, :utc_datetime_usec do
      default &DateTime.utc_now/0
    end
  end

  relationships do
    belongs_to :post, MyApp.Post, primary_key?: true, allow_nil?: false
    belongs_to :tag, MyApp.Tag, primary_key?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
```

## Loading Relationships

```elixir
# Using code interface options (preferred)
post = MyDomain.get_post!(id, load: [:author, comments: [:author]])

# Complex loading with filters
posts = MyDomain.list_posts!(
  query: [load: [comments: [filter: [is_approved: true], limit: 5]]]
)

# Manual query building (for complex cases)
MyApp.Post
|> Ash.Query.load(comments: MyApp.Comment |> Ash.Query.filter(is_approved == true))
|> Ash.read!()

# Loading on existing records
Ash.load!(post, :author)
```

Prefer to use the `strict?` option when loading to only load necessary fields on related data.

```elixir
MyApp.Post
|> Ash.Query.load([comments: [:title]], strict?: true)
```

## Managing Relationships

There are two primary ways to manage relationships in Ash:

### 1. Using `change manage_relationship/2-3` in Actions
Use this when input comes from action arguments:

```elixir
actions do
  update :update do
    # Define argument for the related data
    argument :comments, {:array, :map} do
      allow_nil? false
    end

    argument :new_tags, {:array, :map}

    # Link argument to relationship management
    change manage_relationship(:comments, type: :append)

    # For different argument and relationship names
    change manage_relationship(:new_tags, :tags, type: :append)
  end
end
```

### 2. Using `Ash.Changeset.manage_relationship/3-4` in Custom Changes
Use this when building values programmatically:

```elixir
defmodule MyApp.Changes.AssignTeamMembers do
  use Ash.Resource.Change

  def change(changeset, _opts, context) do
    members = determine_team_members(changeset, context.actor)

    Ash.Changeset.manage_relationship(
      changeset,
      :members,
      members,
      type: :append_and_remove
    )
  end
end
```

### Quick Reference - Management Types
- `:append` - Add new related records, ignore existing
- `:append_and_remove` - Add new related records, remove missing
- `:remove` - Remove specified related records
- `:direct_control` - Full CRUD control (create/update/destroy)
- `:create` - Only create new records

### Quick Reference - Common Options
- `on_lookup: :relate` - Look up and relate existing records
- `on_no_match: :create` - Create if no match found
- `on_match: :update` - Update existing matches
- `on_missing: :destroy` - Delete records not in input
- `value_is_key: :name` - Use field as key for simple values

For comprehensive documentation, see the [Managing Relationships](https://hexdocs.pm/ash/relationships.html#managing-relationships) section.

### Examples

Creating a post with tags:
```elixir
MyDomain.create_post!(%{
  title: "New Post",
  body: "Content here...",
  tags: [%{name: "elixir"}, %{name: "ash"}]  # Creates new tags
})

# Updating a post to replace its tags
MyDomain.update_post!(post, %{
  tags: [tag1.id, tag2.id]  # Replaces tags with existing ones by ID
})
```


<!-- ash:relationships-end -->
<!-- ash:testing-start -->
## ash:testing usage
# Testing

When testing resources:
- Test your domain actions through the code interface
- Use test utilities in `Ash.Test`
- Test authorization policies work as expected using `Ash.can?`
- Use `authorize?: false` in tests where authorization is not the focus
- Write generators using `Ash.Generator`
- Prefer to use raising versions of functions whenever possible, as opposed to pattern matching

## Preventing Deadlocks in Concurrent Tests

When running tests concurrently, using fixed values for identity attributes can cause deadlock errors. Multiple tests attempting to create records with the same unique values will conflict.

### Use Globally Unique Values

Always use globally unique values for identity attributes in tests:

```elixir
# BAD - Can cause deadlocks in concurrent tests
%{email: "test@example.com", username: "testuser"}

# GOOD - Use globally unique values
%{
  email: "test-#{System.unique_integer([:positive])}@example.com",
  username: "user_#{System.unique_integer([:positive])}",
  slug: "post-#{System.unique_integer([:positive])}"
}
```

### Creating Reusable Test Generators

For better organization, create a generator module:

```elixir
defmodule MyApp.TestGenerators do
  use Ash.Generator

  def user(opts \\ []) do
    changeset_generator(
      User,
      :create,
      defaults: [
        email: "user-#{System.unique_integer([:positive])}@example.com",
        username: "user_#{System.unique_integer([:positive])}"
      ],
      overrides: opts
    )
  end
end

# In your tests
test "concurrent user creation" do
  users = MyApp.TestGenerators.generate_many(user(), 10)
  # Each user has unique identity attributes
end
```

This applies to ANY field used in identity constraints, not just primary keys. Using globally unique values prevents frustrating intermittent test failures in CI environments.

<!-- ash:testing-end -->
<!-- ash_ai-start -->
## ash_ai usage
_Integrated LLM features for your Ash application._

[ash_ai usage rules](deps/ash_ai/usage-rules.md)
<!-- ash_ai-end -->
<!-- ash_authentication-start -->
## ash_authentication usage
_Authentication extension for the Ash Framework._

[ash_authentication usage rules](deps/ash_authentication/usage-rules.md)
<!-- ash_authentication-end -->
<!-- ash_phoenix-start -->
## ash_phoenix usage
_Utilities for integrating Ash and Phoenix_

[ash_phoenix usage rules](deps/ash_phoenix/usage-rules.md)
<!-- ash_phoenix-end -->
<!-- ash_postgres-start -->
## ash_postgres usage
_The PostgreSQL data layer for Ash Framework_

[ash_postgres usage rules](deps/ash_postgres/usage-rules.md)
<!-- ash_postgres-end -->
<!-- usage-rules-end -->
