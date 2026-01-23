import gleam/json
import gleam/list
import inertia_wisp/ssr.{type PageLayout}
import nakai
import nakai/attr
import nakai/html
import shared/vite.{type Manifest}
import wisp.{type Request, type Response}

pub type Context {
  Context(
    static_directory: String,
    manifest: Manifest,
    ssr_layout: fn(PageLayout) -> fn(String, json.Json) -> String,
  )
}

pub fn middleware(
  req: Request,
  ctx: Context,
  handle_request: fn(Request) -> Response,
) -> Response {
  let req = wisp.method_override(req)
  use <- wisp.log_request(req)
  use <- wisp.rescue_crashes
  use req <- wisp.handle_head(req)
  use <- wisp.serve_static(req, under: "/static", from: ctx.static_directory)

  handle_request(req)
}

pub fn layout(ctx: Context) -> PageLayout {
  let assert Ok(main_js) = vite.asset(ctx.manifest, "src/main.jsx", "/static")
  fn(head: List(String), body: String) -> String {
    layout_html(head, body, main_js)
  }
}

fn layout_html(head: List(String), body: String, main_js: String) -> String {
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
      html.Script([attr.src(main_js)], ""),
    ]),
  ])
  |> nakai.to_string
}
