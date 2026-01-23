import gleam/dynamic.{type Dynamic}
import gleam/javascript/promise.{type Promise}

pub type RenderModule

pub type RenderedPage {
  RenderedPage(head: List(String), body: String)
}

pub type RenderError {
  ModuleNotFound(String)
  NoRenderExport(String)
  RenderFailed(String)
}

@external(javascript, "../ssr_server_ffi.mjs", "loadModule")
pub fn load_module(path: String) -> Result(RenderModule, RenderError)

@external(javascript, "../ssr_server_ffi.mjs", "callRender")
pub fn call_render(
  module: RenderModule,
  page: Dynamic,
) -> Promise(Result(RenderedPage, RenderError))
