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
import inertia_wisp/ssr/internal/protocol
import logging

/// Page layout function that receives SSR head elements and body content.
/// - `head`: List of HTML strings for the `<head>` section (scripts, styles, meta tags)
/// - `body`: The rendered HTML body content
pub type PageLayout =
  fn(List(String), String) -> String

/// Layout handler function returned by `layout()`.
/// Takes the component name and page data JSON, returns rendered HTML.
pub type LayoutHandler =
  fn(String, Json) -> String

/// Type alias for pool names - a typed handle for pool lookup.
/// Create pool names using `process.new_name()` at application startup.
pub type PoolName =
  pool.PoolName

/// Configuration for the SSR pool and rendering behavior.
///
/// ## Fields
///
/// - `module_path`: Absolute path to the JavaScript SSR module (use `priv_path` to resolve)
/// - `name`: Pool name for registration (default: uses default name)
/// - `node_path`: Optional custom path to Node.js executable (default: None, uses system PATH)
/// - `pool_size`: Number of persistent Node.js worker processes (default: 4)
/// - `timeout`: Maximum time to wait for SSR rendering (default: 1 second)
pub type SsrConfig {
  SsrConfig(
    module_path: String,
    name: PoolName,
    node_path: Option(String),
    pool_size: Int,
    timeout: Duration,
  )
}

/// Resolve a path relative to an OTP application's priv directory.
///
/// Call this at application startup to get the absolute path for `SsrConfig`.
/// In Erlang releases, the priv directory location is unpredictable, so this
/// function uses the OTP application system to resolve it correctly.
///
/// Falls back to `"priv/" <> path` if the application is not loaded.
///
/// ## Example
///
/// ```gleam
/// let module_path = ssr.priv_path("my_app", "ssr/ssr.js")
/// let config = SsrConfig(..ssr.default_config(), module_path: module_path)
/// ```
pub fn priv_path(app_name: String, path: String) -> String {
  case application.priv_directory(app_name) {
    Ok(priv) -> priv <> "/" <> path
    Error(_) -> "priv/" <> path
  }
}

/// Create a default SSR configuration.
///
/// Uses a default pool name, "priv/ssr/ssr.js" as module path, 4 workers,
/// and 1s timeout. For production releases, use `priv_path()` to resolve
/// the module path correctly.
///
/// ## Example
///
/// ```gleam
/// let config = SsrConfig(
///   ..ssr.default_config(),
///   module_path: ssr.priv_path("my_app", "ssr/ssr.js"),
/// )
/// ```
///
/// **Note**: This function creates a new pool name each time it's called.
/// For multiple pools, create specific names with `process.new_name()` at startup.
pub fn default_config() -> SsrConfig {
  SsrConfig(
    module_path: "priv/ssr/ssr.js",
    name: process.new_name("inertia_wisp_ssr"),
    node_path: None,
    pool_size: 4,
    timeout: duration.seconds(1),
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
///   let config = SsrConfig(
///     ..ssr.default_config(),
///     module_path: ssr.priv_path("my_app", "ssr/ssr.js"),
///   )
///   supervisor.new(supervisor.OneForOne)
///   |> supervisor.add(ssr.supervised(config))
///   |> supervisor.start
/// }
/// ```
pub fn supervised(config: SsrConfig) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    pool.start(
      config.name,
      config.module_path,
      config.node_path,
      config.pool_size,
    )
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
pub fn layout(config: SsrConfig, template: PageLayout) -> LayoutHandler {
  fn(component: String, page_data: Json) -> String {
    case pool.render(config.name, page_data, config.timeout) {
      Ok(protocol.Page(head:, body:)) -> {
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
/// **Deprecated**: Use `ssr.layout(config, _)` instead for the same behavior
/// with less indirection.
///
/// ## Example
///
/// ```gleam
/// // Preferred: use function hole syntax
/// |> inertia.response(200, ssr.layout(config, _)(my_template))
///
/// // Or with partial application stored in context:
/// let layout = ssr.layout(config, _)
/// |> inertia.response(200, layout(my_template))
/// ```
@deprecated("Use `ssr.layout(config, _)` instead")
pub fn make_layout(config: SsrConfig) -> fn(PageLayout) -> LayoutHandler {
  fn(template: PageLayout) { layout(config, template) }
}

fn csr_fallback(template: PageLayout, page_data: Json) -> String {
  let page_json = json.to_string(page_data)
  let escaped_json = html.escape_html(page_json)
  let fallback_body =
    "<div id=\"app\" data-page=\"" <> escaped_json <> "\"></div>"
  template([], fallback_body)
}
