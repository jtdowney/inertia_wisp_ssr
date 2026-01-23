//// Server-side rendering support for Inertia.js applications.
////
//// This module provides the public API for adding SSR to your Inertia
//// handlers. It wraps your HTML template function to first attempt
//// server-side rendering via Node.js, falling back to client-side
//// rendering if SSR fails.

import gleam/erlang/application
import gleam/erlang/process
import gleam/json.{type Json}
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
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

/// Type alias for pool names - a typed handle for pool lookup.
/// Create pool names using `process.new_name()` at application startup.
pub type PoolName =
  pool.PoolName

/// Configuration for the SSR pool and rendering behavior.
///
/// ## Fields
///
/// - `app_name`: OTP application name for priv directory resolution (required)
/// - `module_path`: Path to the JavaScript SSR module relative to priv directory (default: "ssr/ssr.js")
/// - `name`: Pool name for registration (default: uses default name)
/// - `node_path`: Optional custom path to Node.js executable (default: None, uses system PATH)
/// - `pool_size`: Number of persistent Node.js worker processes (default: 4)
/// - `timeout`: Maximum time to wait for SSR rendering (default: 1 second)
pub type SsrConfig {
  SsrConfig(
    app_name: String,
    module_path: String,
    name: PoolName,
    node_path: Option(String),
    pool_size: Int,
    timeout: Duration,
  )
}

/// Create a default SSR configuration for the given OTP application.
///
/// The `app_name` is used to resolve the priv directory at runtime, which is
/// required for SSR to work correctly in Erlang releases where the working
/// directory is unpredictable.
///
/// Uses default pool name, "ssr/ssr.js" as module path (relative to priv),
/// 4 workers, and 1s timeout.
///
/// **Note**: This function creates a new pool name each time it's called.
/// For multiple pools, create specific names with `process.new_name()` at startup.
pub fn default_config(app_name: String) -> SsrConfig {
  SsrConfig(
    app_name: app_name,
    module_path: "ssr/ssr.js",
    name: process.new_name("inertia_wisp_ssr"),
    node_path: None,
    pool_size: 4,
    timeout: duration.seconds(1),
  )
}

/// Get a child specification for adding the SSR pool to your supervision tree.
///
/// The pool is registered under the name in `config`, allowing `make_layout()`
/// to look it up automatically. The `module_path` is resolved relative to the
/// application's priv directory using `app_name`.
///
/// ## Example
///
/// ```gleam
/// import gleam/otp/static_supervisor as supervisor
/// import inertia_wisp/ssr
///
/// pub fn start_app() {
///   let config = ssr.default_config("my_app")
///   supervisor.new(supervisor.OneForOne)
///   |> supervisor.add(ssr.supervised(config))
///   |> supervisor.start
/// }
/// ```
pub fn supervised(config: SsrConfig) -> ChildSpecification(Nil) {
  let module_path = case string.starts_with(config.module_path, "/") {
    True -> config.module_path
    False ->
      case application.priv_directory(config.app_name) {
        Ok(priv) -> priv <> "/" <> config.module_path
        Error(_) -> "priv/" <> config.module_path
      }
  }

  supervision.worker(fn() {
    pool.start(config.name, module_path, config.node_path, config.pool_size)
    |> result.map(fn(pid) { actor.Started(pid, Nil) })
    |> result.map_error(fn(_) { actor.InitFailed("pool start failed") })
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
    let frame = protocol.encode_request(page_data)

    case pool.render(config.name, frame, config.timeout) {
      Ok(Page(head:, body:)) -> {
        template(head, body)
      }
      Error(reason) -> {
        let _ =
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
/// let layout = ssr.make_layout(ssr.default_config("my_app"))
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
