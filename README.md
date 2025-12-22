# inertia_wisp_ssr

[![Package Version](https://img.shields.io/hexpm/v/inertia_wisp_ssr)](https://hex.pm/packages/inertia_wisp_ssr)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/inertia_wisp_ssr/)

Server-side rendering (SSR) support for [inertia_wisp](https://hex.pm/packages/inertia_wisp). Renders Inertia.js pages on the server using a supervised pool of Node.js processes, with automatic fallback to client-side rendering if SSR fails.

## Installation

Add `inertia_wisp_ssr` to your `gleam.toml`:

```sh
gleam add inertia_wisp_ssr
```

## Quick Start

> [!IMPORTANT]
> Create your `SsrConfig` once and reuse it. Each call to `default_config()` or `pool_name()` generates a unique pool name—calling them multiple times will cause SSR to silently fall back to CSR.

### 1. Add SSR to Your Supervision Tree

Add the SSR supervisor to your application's supervision tree:

```gleam
import gleam/otp/static_supervisor as supervisor
import inertia_wisp_ssr

pub fn start_app() {
  let config = inertia_wisp_ssr.default_config()

  supervisor.new(supervisor.OneForOne)
  |> supervisor.add(inertia_wisp_ssr.child_spec(config))
  // |> supervisor.add(other_children...)
  |> supervisor.start
}
```

### 2. Create an SSR-Enabled Layout

Create a layout factory once at startup, then use it in your handlers:

```gleam
import gleam/string
import inertia_wisp/inertia
import inertia_wisp_ssr

// Create layout factory once (at module level or during startup)
// The pool is looked up by name from config automatically
const config = inertia_wisp_ssr.default_config()
const layout = inertia_wisp_ssr.make_layout(config)

fn my_layout(head: List(String), body: String) -> String {
  "<!DOCTYPE html>
  <html>
    <head>
      <meta charset=\"utf-8\">
      <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">
      " <> string.join(head, "\n") <> "
    </head>
    <body>
      " <> body <> "
      <script src=\"/app.js\"></script>
    </body>
  </html>"
}

pub fn handle_request(req: Request) -> Response {
  req
  |> inertia.response_builder("Home")
  |> inertia.props(my_props, encode_props)
  |> inertia.response(200, layout(my_layout))
}
```

### 3. Create Your SSR Bundle

Create `priv/ssr/ssr.js` with a `render` function that returns `{ head, body }`:

**React Example:**

```javascript
import { createInertiaApp } from "@inertiajs/react";
import ReactDOMServer from "react-dom/server";

const pages = import.meta.glob("./pages/**/*.jsx", { eager: true });

export async function render(page) {
  return createInertiaApp({
    page,
    render: ReactDOMServer.renderToString,
    resolve: (name) => pages[`./pages/${name}.jsx`],
    setup({ App, props }) {
      return <App {...props} />;
    },
  });
}
```

**Vue Example:**

```javascript
import { createSSRApp, h } from "vue";
import { renderToString } from "vue/server-renderer";
import { createInertiaApp } from "@inertiajs/vue3";

const pages = import.meta.glob("./pages/**/*.vue", { eager: true });

export async function render(page) {
  return createInertiaApp({
    page,
    render: renderToString,
    resolve: (name) => pages[`./pages/${name}.vue`],
    setup({ App, props, plugin }) {
      return createSSRApp({ render: () => h(App, props) }).use(plugin);
    },
  });
}
```

**Svelte Example:**

```javascript
import { createInertiaApp } from "@inertiajs/svelte";
import { render as renderToString } from "svelte/server";

const pages = import.meta.glob("./pages/**/*.svelte", { eager: true });

export async function render(page) {
  return createInertiaApp({
    page,
    resolve: (name) => pages[`./pages/${name}.svelte`],
    setup({ App, props }) {
      return renderToString(App, { props });
    },
  });
}
```

## Configuration

Customize the SSR configuration:

```gleam
import gleam/otp/static_supervisor as supervisor
import inertia_wisp_ssr.{SsrConfig}

let config = SsrConfig(
  name: inertia_wisp_ssr.pool_name("my_app_ssr"),  // Pool process name
  module_path: "priv/ssr/ssr.js",                   // Path to JS bundle
  pool_size: 8,                                     // Number of workers
  timeout: 10_000,                                  // Render timeout (ms)
)

// Add to supervision tree
supervisor.new(supervisor.OneForOne)
|> supervisor.add(inertia_wisp_ssr.child_spec(config))
|> supervisor.start

// Create layout factory with custom config
let layout = inertia_wisp_ssr.make_layout(config)

// Use in handlers
|> inertia.response(200, layout(my_template))
```

### Options

- **`name`** - Pool process name for lookup (default: `"inertia_wisp_ssr"`)
- **`module_path`** - Path to your SSR JavaScript bundle (default: `"priv/ssr/ssr.js"`)
- **`pool_size`** - Number of Node.js worker processes for parallel rendering (default: `4`)
- **`timeout`** - Render timeout in milliseconds (default: `5000`)

## How It Works

### SSR Flow

1. Your handler calls `inertia.response()` with `layout(template)` from `inertia_wisp_ssr.make_layout(config)`
2. The SSR layer attempts to render the page using Node.js:
   - Serializes the Inertia page data to JSON
   - Calls your `ssr.js` `render()` function via the Node.js process pool
   - Receives `{ head, body }` from JavaScript
   - Passes the result to your template function
3. Returns the fully-rendered HTML response

### CSR Fallback

If SSR fails (Node.js error, timeout, or invalid response), the system automatically falls back to client-side rendering:

- Logs a warning with the failure reason
- Generates a `<div id="app" data-page="...">` element with escaped JSON
- Your JavaScript bundle hydrates on the client as normal

This ensures your app remains available even if SSR breaks.

## Requirements

- **Gleam 1.13+** (compiles to Erlang)
- **OTP 27+**
- **Node.js 20+** with your framework's SSR dependencies installed

> [!IMPORTANT]
> Set `NODE_ENV=production` so the SSR script is cached in memory. Without this, page rendering times will be very slow.

## Documentation

Full API documentation is available on [HexDocs](https://hexdocs.pm/inertia_wisp_ssr/).

## License

MIT
