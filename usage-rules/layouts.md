# Layouts

## Core Concept

- Layouts are regular components (`use Hologram.Component`) that serve as the root of the component tree.
- They have no special features beyond being the wrapper for page content.
- The layout's `cid` is always `"layout"`.

## Do

- Include `<Hologram.UI.Runtime />` inside the `<head>` tag — it loads the Hologram runtime and page JS bundles.
- Include `<slot />` in the layout template where the page content should be inserted.
- Accept props for dynamic values like `page_title` using `prop/2` or `prop/3`.
- Specify the layout for a page with `layout/1` or `layout/2` (with props).
- Target the layout in event bindings with `target: "layout"`.

## Don't

- Don't forget `<Hologram.UI.Runtime />` in the head — without it, the client runtime won't load.
- Don't forget `<slot />` — without it, the page content won't render.
- Don't use `use Hologram.Page` or any special macro for layouts — they are plain components.
- Don't create layouts without a full HTML structure (`<html>`, `<head>`, `<body>`) — they serve as the document root.
