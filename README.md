# inertia_wisp_ssr

[![Package Version](https://img.shields.io/hexpm/v/inertia_wisp_ssr)](https://hex.pm/packages/inertia_wisp_ssr)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/inertia_wisp_ssr/)

Server-side rendering (SSR) support for [inertia_wisp](https://hex.pm/packages/inertia_wisp). Renders Inertia.js pages on the server using a supervised pool of Node.js processes, with automatic fallback to client-side rendering if SSR fails.

## Installation

Add the dependency:

```sh
gleam add inertia_wisp_ssr
```

## Quick Start

### 1. Add SSR to Your Supervision Tree

Build the config once at startup, start the pool under your supervisor, and
create the layout from the same config:

```gleam
import gleam/otp/static_supervisor as supervisor
import inertia_wisp/ssr.{SsrConfig}

pub fn start_app() {
  let config = SsrConfig(
    ..ssr.default_config(),
    module_path: ssr.priv_path("my_app", "ssr/ssr.js"),
  )

  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(ssr.supervised(config))
    // |> supervisor.add(other_children...)
    |> supervisor.start

  // Pass `layout` to your handlers through your context.
  let layout = ssr.layout(config, _)
}
```

> [!WARNING]
> Use the same `config` value for `ssr.supervised` and `ssr.layout`. Each call
> to `ssr.default_config()` creates a new pool name, and a layout built from a
> different config can't find the pool, so every page falls back to
> client-side rendering.

### 2. Write Your HTML Template

Your template receives the `<head>` elements and the rendered body. This example uses [nakai](https://hex.pm/packages/nakai) for type-safe HTML generation:

```gleam
import gleam/list
import inertia_wisp/inertia
import inertia_wisp/ssr
import nakai
import nakai/attr
import nakai/html

fn my_layout(head: List(String), body: String) -> String {
  html.Html([attr.Attr("lang", "en")], [
    html.Head(
      list.flatten([
        [
          html.meta([attr.charset("utf-8")]),
          html.meta([
            attr.name("viewport"),
            attr.content("width=device-width, initial-scale=1"),
          ]),
        ],
        list.map(head, html.UnsafeInlineHtml),
      ]),
    ),
    html.Body([], [
      html.UnsafeInlineHtml(body),
      html.Script([attr.src("/app.js")], ""),
    ]),
  ])
  |> nakai.to_string
}

pub fn handle_request(
  req: Request,
  layout: fn(ssr.PageLayout) -> ssr.LayoutHandler,
) -> Response {
  req
  |> inertia.response_builder("Home")
  |> inertia.props(my_props, encode_props)
  |> inertia.response(200, layout(my_layout))
}
```

### 3. Create Your SSR Bundle

Create `priv/ssr/ssr.js` exporting a `render` function that returns `{ head, body }`, where `head` is an array of HTML strings and `body` is an HTML string:

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

### 4. Configure Vite for SSR

Vite externalizes dependencies by default during SSR builds. For SSR to work correctly, configure Vite to bundle all dependencies:

```javascript
// vite.config.js
export default defineConfig({
  ssr: {
    noExternal: false,
  },
});
```

## Configuration

Customize the SSR configuration:

```gleam
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor as supervisor
import gleam/time/duration
import inertia_wisp/ssr.{SsrConfig}

let config = SsrConfig(
  module_path: ssr.priv_path("my_app", "ssr/ssr.js"),  // Absolute path to JS bundle
  name: process.new_name("my_app_ssr"),                // Pool process name
  node_path: None,                                     // Use system Node.js (or Some("/path/to/node"))
  pool_size: 8,                                        // Number of workers
  timeout: duration.seconds(5),                        // Render timeout
)

// Add to supervision tree
supervisor.new(supervisor.OneForOne)
|> supervisor.add(ssr.supervised(config))
|> supervisor.start

// Create layout factory with custom config
let layout = ssr.layout(config, _)

// Use in handlers
|> inertia.response(200, layout(my_template))
```

### Options

| Field         | Default                                | Meaning                                                                                         |
| ------------- | -------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `module_path` | `"priv/ssr/ssr.js"`                    | Path to your SSR bundle. Use `ssr.priv_path(app_name, path)` so it resolves in Erlang releases. |
| `name`        | `process.new_name("inertia_wisp_ssr")` | Name the pool registers under.                                                                  |
| `node_path`   | `None`                                 | Path to the `node` executable. `None` uses the system PATH.                                     |
| `pool_size`   | `4`                                    | Number of Node.js worker processes.                                                             |
| `timeout`     | `duration.seconds(1)`                  | How long a render may take before falling back to client-side rendering.                        |

## How It Works

### SSR Flow

1. Your handler calls `inertia.response()` with `layout(template)` from `ssr.layout(config, _)`
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
- Your client bundle renders the page from `data-page` as it would without SSR

## Requirements

- Gleam 1.17+ on the Erlang target
- OTP 27+
- Node.js 22+ with your framework's SSR dependencies installed

> [!IMPORTANT]
> Set `NODE_ENV=production` in production. Without it, each worker reloads your SSR bundle from disk on every render. That picks up changes during development but makes rendering slow.

## Debugging

Set `DEBUG_SSR=1` (or `DEBUG_SSR=true`) to have the Node.js workers print trace messages to stderr: module loads, connections, and request and response sizes.
