//// Server-side rendering for Inertia.js pages served by inertia_wisp.
////
//// Wraps your HTML template so each page is rendered by a pool of Node.js
//// workers, falling back to client-side rendering when SSR fails.

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

/// Your HTML template. Receives the `<head>` elements (title, meta, styles)
/// and the rendered body HTML, and returns the full document.
pub type PageLayout =
  fn(List(String), String) -> String

/// Layout returned by `layout()`, ready to pass to `inertia.response`.
pub type LayoutHandler =
  fn(String, Json) -> String

/// Name the SSR pool is registered under. Create one with
/// `process.new_name()` at startup.
pub type PoolName =
  pool.PoolName

/// Configuration for the SSR pool and rendering.
///
/// `module_path` should be absolute; use `priv_path` to build it. A
/// `node_path` of `None` finds `node` on the system PATH. `timeout` is how
/// long a render may take before falling back to client-side rendering.
///
/// Pass the same config value to both `supervised` and `layout`. The pool is
/// found by `name`, so a config with a different name renders every page
/// client-side.
pub type SsrConfig {
  SsrConfig(
    module_path: String,
    name: PoolName,
    node_path: Option(String),
    pool_size: Int,
    timeout: Duration,
  )
}

/// Resolve a path inside an OTP application's priv directory.
///
/// Use this for `module_path` so the bundle is found in Erlang releases,
/// where priv is not relative to the working directory. Falls back to
/// `"priv/" <> path` if the application is not loaded.
pub fn priv_path(app_name: String, path: String) -> String {
  case application.priv_directory(app_name) {
    Ok(priv) -> priv <> "/" <> path
    Error(_) -> "priv/" <> path
  }
}

/// Default configuration: `priv/ssr/ssr.js` relative to the working
/// directory, 4 workers, a 1 second timeout, and the system `node`.
///
/// Each call creates a new pool name, so call it once and share the result
/// between `supervised` and `layout`.
///
/// ```gleam
/// let config = ssr.SsrConfig(
///   ..ssr.default_config(),
///   module_path: ssr.priv_path("my_app", "ssr/ssr.js"),
/// )
/// ```
pub fn default_config() -> SsrConfig {
  SsrConfig(
    module_path: "priv/ssr/ssr.js",
    name: process.new_name("inertia_wisp_ssr"),
    node_path: None,
    pool_size: 4,
    timeout: duration.seconds(1),
  )
}

/// Child specification for the SSR pool. The pool registers under
/// `config.name`, which is how `layout` finds it.
///
/// ```gleam
/// supervisor.new(supervisor.OneForOne)
/// |> supervisor.add(ssr.supervised(config))
/// |> supervisor.start
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

/// Wrap a template so pages are rendered on the server.
///
/// If the render fails or times out, logs a warning and calls the template
/// with an empty head and a `<div id="app" data-page="...">` body so the
/// client can render the page instead.
///
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
/// // In a handler:
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

/// Deprecated: use `ssr.layout(config, _)` instead.
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
