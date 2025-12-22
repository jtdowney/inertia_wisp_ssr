import gleam/dict
import gleam/http
import gleam/json
import hello_vue/web.{type Context}
import inertia_wisp/inertia
import wisp.{type Request, type Response}

pub fn handle_request(req: Request, ctx: Context) -> Response {
  use req <- web.middleware(req, ctx)

  case wisp.path_segments(req) {
    [] -> home(req, ctx)
    ["about"] -> about(req, ctx)
    _ -> wisp.not_found()
  }
}

type HomeProps {
  HomeProps(name: String)
}

fn encode_home_props(props: HomeProps) -> dict.Dict(String, json.Json) {
  dict.from_list([#("name", json.string(props.name))])
}

fn home(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)

  let props = HomeProps(name: "World")
  let layout = ctx.ssr_layout(web.layout(ctx))

  req
  |> inertia.response_builder("Home")
  |> inertia.props(props, encode_home_props)
  |> inertia.response(200, layout)
}

type AboutProps {
  AboutProps
}

fn encode_about_props(_props: AboutProps) -> dict.Dict(String, json.Json) {
  dict.new()
}

fn about(req: Request, ctx: Context) -> Response {
  use <- wisp.require_method(req, http.Get)
  let layout = ctx.ssr_layout(web.layout(ctx))

  req
  |> inertia.response_builder("About")
  |> inertia.props(AboutProps, encode_about_props)
  |> inertia.response(200, layout)
}
