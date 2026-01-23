# Hello Svelte

Minimal Svelte 5 + Inertia.js SSR example with a Gleam backend using `inertia_wisp_ssr`.

## Setup

```bash
# Install JS dependencies and build SSR bundle
npm install
npm run build:ssr

# Build and run Gleam app
gleam run
```

The server starts at http://localhost:3000

## Project Structure

```
hello-svelte/
├── gleam.toml              # Gleam project config
├── package.json            # JS dependencies
├── vite.config.js          # Vite build config
├── svelte.config.js        # Svelte compiler config
├── src/
│   ├── hello_svelte.gleam          # Main entrypoint
│   ├── hello_svelte/
│   │   ├── router.gleam            # Route handlers
│   │   └── web.gleam               # Middleware & HTML template
│   ├── main.js                     # Client hydration
│   ├── ssr.js                      # SSR render function
│   └── pages/
│       └── Home.svelte             # Page component (Svelte 5 runes)
└── priv/
    ├── static/                     # Client bundle (after build)
    └── ssr/
        └── ssr.js                  # SSR bundle (after build:ssr)
```

## Svelte 5 Features

This example uses Svelte 5's runes syntax:

```svelte
<script>
  let { name } = $props();
</script>
```

## How It Works

1. Gleam app starts the Node.js SSR pool via `inertia_wisp_ssr.child_spec(config)`
2. Routes call `inertia.response()` with `layout(web.layout(ctx))` from `ssr.layout(config, _)`
3. SSR pool calls `render(pageJson)` in the JS bundle
4. Response includes server-rendered HTML with hydration data
