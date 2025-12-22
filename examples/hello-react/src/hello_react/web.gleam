import gleam/json
import gleam/string
import inertia_wisp_ssr.{type PageLayout}
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
  "<!DOCTYPE html>
<html lang=\"en\">
  <head>
    <meta charset=\"utf-8\" />
    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
    " <> string.join(head, "\n    ") <> "
  </head>
  <body>
    " <> body <> "
    <script type=\"module\" src=\"" <> main_js <> "\"></script>
  </body>
</html>"
}
