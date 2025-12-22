//// Server-side rendering support for Inertia.js applications.
////
//// This module provides the public API for adding SSR to your Inertia
//// handlers. It wraps your HTML template function to first attempt
//// server-side rendering via Node.js, falling back to client-side
//// rendering if SSR fails.
////
//// ## Setup
////
//// 1. Add SSR to your supervision tree using `child_spec()`
//// 2. Create a JavaScript SSR bundle that exports a `render` function
//// 3. Wrap your layout function with `make_layout()` or `layout()`
////
//// ## Complete Example
////
//// ```gleam
//// import gleam/otp/static_supervisor as supervisor
//// import gleam/string
//// import inertia_wisp/inertia
//// import inertia_wisp_ssr
//// import wisp.{type Request, type Response}
////
//// // Create config (uses default pool name)
//// const config = inertia_wisp_ssr.default_config()
////
//// // Create layout factory (looks up pool by name from config)
//// const layout = inertia_wisp_ssr.make_layout(config)
////
//// pub fn start_app() {
////   // Add SSR to your supervision tree
////   let assert Ok(_) = supervisor.new(supervisor.OneForOne)
////     |> supervisor.add(inertia_wisp_ssr.child_spec(config))
////     |> supervisor.start
////
////   // Start your web server...
//// }
////
//// fn my_layout(head: List(String), body: String) -> String {
////   "<!DOCTYPE html>
////   <html>
////     <head>
////       <meta charset=\"utf-8\">
////       " <> string.join(head, "\n") <> "
////     </head>
////     <body>
////       " <> body <> "
////       <script src=\"/app.js\"></script>
////     </body>
////   </html>"
//// }
////
//// pub fn home_handler(req: Request) -> Response {
////   req
////   |> inertia.response_builder("Home")
////   |> inertia.props(my_props, encode_props)
////   |> inertia.response(200, layout(my_layout))
//// }
//// ```
////
//// ## JavaScript SSR Bundle
////
//// Create `priv/ssr/ssr.js` with a `render` function:
////
//// ```javascript
//// import { createInertiaApp } from '@inertiajs/react';
//// import ReactDOMServer from 'react-dom/server';
////
//// const pages = import.meta.glob('./pages/**/*.jsx', { eager: true });
////
//// export async function render(page) {
////   return createInertiaApp({
////     page,
////     render: ReactDOMServer.renderToString,
////     resolve: (name) => pages[`./pages/${name}.jsx`],
////     setup({ App, props }) {
////       return <App {...props} />;
////     },
////   });
//// }
//// ```

import bath
import gleam/erlang/process
import gleam/json
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import inertia_wisp/html
import inertia_wisp_ssr/internal/protocol.{SsrRenderError, SsrSuccess}
import inertia_wisp_ssr/internal/worker.{type Worker}
import logging

/// Page layout function that receives SSR head elements and body content.
/// - `head`: List of HTML strings for the `<head>` section (scripts, styles, meta tags)
/// - `body`: The rendered HTML body content
pub type PageLayout =
  fn(List(String), String) -> String

/// Name for the SSR pool process.
/// Create with `pool_name()` and use the same name in both config and lookups.
pub opaque type PoolName {
  PoolName(inner: process.Name(bath.Msg(Worker)))
}

/// Create a pool name from a string.
///
/// **Important:** Call this function once and reuse the returned `PoolName`.
/// Each call generates a unique process name, so the same string called twice
/// will produce different pool references.
pub fn pool_name(name: String) -> PoolName {
  PoolName(process.new_name(name))
}

/// Configuration for starting the SSR pool.
pub type SsrConfig {
  SsrConfig(
    /// Name for the pool process (for supervised lookup)
    name: PoolName,
    /// Path to the SSR JavaScript module (e.g., "priv/ssr/ssr.js")
    module_path: String,
    /// Number of Node.js worker processes (default: 4)
    pool_size: Int,
    /// Render timeout in milliseconds (default: 5000)
    timeout: Int,
  )
}

/// Create a default SSR configuration.
/// Uses default pool name, "priv/ssr/ssr.js" as module path, 4 workers, and 5000ms timeout.
///
/// **Important:** Call this function once and reuse the returned config.
/// Each call generates a unique pool name, so calling it multiple times
/// will result in mismatched pool references and SSR will silently fall back to CSR.
///
/// ```gleam
/// // Correct: define once, reuse everywhere
/// const config = inertia_wisp_ssr.default_config()
///
/// // Wrong: different configs won't find each other
/// let spec = child_spec(default_config())  // pool A
/// let layout = make_layout(default_config())  // looks for pool B!
/// ```
pub fn default_config() -> SsrConfig {
  SsrConfig(
    name: pool_name("inertia_wisp_ssr"),
    module_path: "priv/ssr/ssr.js",
    pool_size: 4,
    timeout: 5000,
  )
}

/// Get a child specification for adding the SSR pool to your supervision tree.
///
/// The pool is registered under the name in `config`, allowing `make_layout()`
/// to look it up automatically.
///
/// ## Example
///
/// ```gleam
/// import gleam/otp/static_supervisor as supervisor
/// import inertia_wisp_ssr
///
/// pub fn start_app() {
///   let config = inertia_wisp_ssr.default_config()
///   supervisor.new(supervisor.OneForOne)
///   |> supervisor.add(inertia_wisp_ssr.child_spec(config))
///   |> supervisor.start
/// }
/// ```
pub fn child_spec(config: SsrConfig) -> ChildSpecification(Nil) {
  let PoolName(name) = config.name
  bath.new(fn() { worker.start(config.module_path) })
  |> bath.size(config.pool_size)
  |> bath.name(name)
  |> bath.on_shutdown(fn(w) { worker.stop(w) })
  |> bath.supervised_map(fn(_) { Nil }, 5000)
}

/// Wrap a template function to enable server-side rendering.
///
/// The template function receives:
/// - `head`: List of HTML strings for the `<head>` section
/// - `body`: The rendered HTML body content
///
/// If SSR fails, this automatically falls back to client-side rendering.
///
/// ## Example
///
/// ```gleam
/// fn my_layout(head: List(String), body: String) -> String {
///   "<!DOCTYPE html><html><head>"
///   <> string.join(head, "\n")
///   <> "</head><body>"
///   <> body
///   <> "<script src='/app.js'></script></body></html>"
/// }
///
/// // In handler:
/// |> inertia.response(200, inertia_wisp_ssr.layout(config, my_layout))
/// ```
pub fn layout(
  config: SsrConfig,
  template: PageLayout,
) -> fn(String, json.Json) -> String {
  fn(component: String, page_data: json.Json) -> String {
    case render(config, page_data) {
      Ok(SsrSuccess(head, body)) -> {
        template(head, body)
      }
      Ok(SsrRenderError(reason)) -> {
        logging.log(
          logging.Warning,
          "SSR render error for component "
            <> component
            <> ", falling back to CSR: "
            <> reason,
        )
        csr_fallback(template, page_data)
      }
      Error(reason) -> {
        logging.log(
          logging.Warning,
          "SSR failed for component "
            <> component
            <> ", falling back to CSR: "
            <> reason,
        )
        csr_fallback(template, page_data)
      }
    }
  }
}

/// Create a reusable layout function with SSR configuration baked in.
///
/// Call this once at startup and reuse the returned function in handlers.
///
/// ## Example
///
/// ```gleam
/// // At startup
/// let layout = inertia_wisp_ssr.make_layout(inertia_wisp_ssr.default_config())
///
/// // In handler
/// |> inertia.response(200, layout(my_template))
/// ```
pub fn make_layout(
  config: SsrConfig,
) -> fn(PageLayout) -> fn(String, json.Json) -> String {
  fn(template: PageLayout) { layout(config, template) }
}

fn render(
  config: SsrConfig,
  page_data: json.Json,
) -> Result(protocol.SsrResult, String) {
  let PoolName(name) = config.name
  let pool = process.named_subject(name)
  case process.subject_owner(pool) {
    Error(Nil) -> Error("SSR pool not started")
    Ok(_) ->
      bath.apply(pool, config.timeout, fn(w) {
        bath.returning(bath.keep(), worker.call(w, page_data, config.timeout))
      })
      |> result.map_error(bath_error_to_string)
      |> result.flatten
  }
}

fn bath_error_to_string(err: bath.ApplyError) -> String {
  case err {
    bath.NoResourcesAvailable -> "no workers available"
    bath.CheckOutResourceCreateError(reason) -> reason
  }
}

fn csr_fallback(template: PageLayout, page_data: json.Json) -> String {
  let page_json = json.to_string(page_data)
  let escaped_json = html.escape_html(page_json)
  let fallback_body =
    "<div id=\"app\" data-page=\"" <> escaped_json <> "\"></div>"
  template([], fallback_body)
}
