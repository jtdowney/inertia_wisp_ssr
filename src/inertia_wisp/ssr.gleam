//// Server-side rendering support for Inertia.js applications.
////
//// This module provides the public API for adding SSR to your Inertia
//// handlers. It wraps your HTML template function to first attempt
//// server-side rendering via Node.js, falling back to client-side
//// rendering if SSR fails.

import gleam/erlang/atom.{type Atom}
import gleam/json.{type Json}
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import gleam/time/duration.{type Duration}
import inertia_wisp/html
import inertia_wisp/ssr/internal/pool
import inertia_wisp/ssr/internal/protocol.{Page}
import logging

/// Page layout function that receives SSR head elements and body content.
/// - `head`: List of HTML strings for the `<head>` section (scripts, styles, meta tags)
/// - `body`: The rendered HTML body content
pub type PageLayout =
  fn(List(String), String) -> String

/// Configuration for the SSR pool and rendering behavior.
///
/// ## Fields
///
/// - `max_buffer_size`: Maximum size in bytes for Node.js stdout/stderr buffers (default: 1MB)
/// - `max_overflow`: Maximum number of temporary workers beyond pool_size (default: 2)
/// - `module_path`: Path to the JavaScript SSR module (default: "priv/ssr/ssr.js")
/// - `name`: Atom name for the worker pool registration (default: `inertia_wisp_ssr`)
/// - `node_path`: Optional custom path to Node.js executable (default: None, uses system PATH)
/// - `pool_size`: Number of persistent Node.js worker processes (default: 4)
/// - `timeout`: Maximum time to wait for SSR rendering (default: 5 seconds)
pub type SsrConfig {
  SsrConfig(
    max_buffer_size: Int,
    max_overflow: Int,
    module_path: String,
    name: Atom,
    node_path: Option(String),
    pool_size: Int,
    timeout: Duration,
  )
}

/// Create a default SSR configuration.
/// Uses default pool name, "priv/ssr/ssr.js" as module path, 4 workers,
/// 2 overflow workers, and 5s timeout.
pub fn default_config() -> SsrConfig {
  SsrConfig(
    max_buffer_size: 1_048_576,
    max_overflow: 2,
    module_path: "priv/ssr/ssr.js",
    name: atom.create("inertia_wisp_ssr"),
    node_path: None,
    pool_size: 4,
    timeout: duration.seconds(5),
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
/// import inertia_wisp/ssr
///
/// pub fn start_app() {
///   let config = ssr.default_config()
///   supervisor.new(supervisor.OneForOne)
///   |> supervisor.add(ssr.supervised(config))
///   |> supervisor.start
/// }
/// ```
pub fn supervised(config: SsrConfig) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    case
      pool.start(
        config.name,
        config.module_path,
        config.node_path,
        config.pool_size,
        config.max_overflow,
        config.max_buffer_size,
      )
    {
      Ok(pid) -> Ok(actor.Started(pid, Nil))
      Error(_reason) -> Error(actor.InitFailed("pool start failed"))
    }
  })
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
/// |> inertia.response(200, ssr.layout(config, my_layout))
/// ```
pub fn layout(
  config: SsrConfig,
  template: PageLayout,
) -> fn(String, Json) -> String {
  fn(component: String, page_data: Json) -> String {
    case pool.render(config.name, page_data, config.timeout) {
      Ok(Page(head:, body:)) -> {
        template(head, body)
      }
      Error(reason) -> {
        logging.log(
          logging.Warning,
          "SSR failed for component "
            <> component
            <> ", falling back to CSR: "
            <> string.inspect(reason),
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
/// let layout = ssr.make_layout(ssr.default_config())
///
/// // In handler
/// |> inertia.response(200, layout(my_template))
/// ```
pub fn make_layout(
  config: SsrConfig,
) -> fn(PageLayout) -> fn(String, Json) -> String {
  fn(template: PageLayout) { layout(config, template) }
}

fn csr_fallback(template: PageLayout, page_data: Json) -> String {
  let page_json = json.to_string(page_data)
  let escaped_json = html.escape_html(page_json)
  let fallback_body =
    "<div id=\"app\" data-page=\"" <> escaped_json <> "\"></div>"
  template([], fallback_body)
}
