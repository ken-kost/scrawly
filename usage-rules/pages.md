# Pages

## Module Setup

- Pages use `use Hologram.Page`.
- Every page must define a route with `route/1` and a layout with `layout/1` or `layout/2`.
- Pages are always stateful and always initialized server-side via `init/3`.
- The page's `cid` is always `"page"`.

## Do

- Define routes as static (`route "/products"`) or with dynamic params (`route "/users/:username/posts/:post_id"`).
- Use `param/2` to declare type conversions for route parameters: `param :post_id, :integer`. Supported: `:atom`, `:float`, `:integer`, `:string`.
- Access URL parameters in `init/3` via the first argument (`params`), not as props.
- Use `layout/2` to pass props to the layout: `layout MyApp.MainLayout, page_title: "My Page"`.
- Use `put_action/2` in `init/3` to chain client-side actions on mount.
- Target the page in event bindings with `target: "page"`.

## Don't

- Don't use `use Hologram.Component` for pages — use `use Hologram.Page`.
- Don't define `init/2` on pages — pages always use `init/3` (server-side initialization).
- Don't create ambiguous parameterized routes at the same level (e.g. `/:username` and `/:post_slug`). Use distinct prefixes like `/users/:username` and `/posts/:post_slug`.
- Don't worry about route ordering — Hologram uses a search tree, not ordered matching. Static segments always win over parameterized ones automatically.
- Don't forget that `init/3` receives URL `params` as the first argument, not component props.
