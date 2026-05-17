# Navigation

## Core Concept

- Hologram combines server-side rendering with client-side transitions using the History PushState API and virtual DOM.
- Pages are loaded fresh from the server on each navigation, ensuring up-to-date content.
- Transitions feel instant due to prefetching on `pointer_down`.

## Do

- Use the `Hologram.UI.Link` component for navigation links: `<Link to={MyPage}>Go</Link>`.
- Pass route parameters to links: `<Link to={MyPage, id: 123}>View</Link>`.
- Use `put_page/2` or `put_page/3` in actions for programmatic navigation: `put_page(component, MyPage, id: 123)`.
- Rely on the built-in prefetching — Hologram prefetches on pointer down and swaps on pointer up automatically.
- Trust that back/forward browser navigation works correctly — Hologram manages the history stack.

## Don't

- Don't use raw `<a href="...">` tags for internal navigation — use `<Link>` to get SPA-like transitions with prefetching.
- Don't manually manage browser history or use `pushState` directly — Hologram handles it.
- Don't assume pages persist state across navigation — each page is loaded fresh from the server.
- Don't call `put_page` from commands — use it only in actions (server-side navigation is not yet supported).
