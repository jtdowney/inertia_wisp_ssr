import gleam/erlang/process
import gleam/otp/static_supervisor as supervisor
import hello_vue/router
import hello_vue/web
import inertia_wisp/ssr
import mist
import shared/vite
import wisp
import wisp/wisp_mist

pub fn main() {
  wisp.configure_logger()

  let assert Ok(priv) = wisp.priv_directory("hello_vue")
  let static_directory = priv <> "/static"

  let config = ssr.default_config("hello_vue")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(ssr.supervised(config))
    |> supervisor.start

  let assert Ok(manifest) = vite.load_manifest(static_directory)
  let layout = ssr.make_layout(config)
  let ctx =
    web.Context(
      static_directory: static_directory,
      manifest: manifest,
      ssr_layout: layout,
    )

  let secret_key_base = wisp.random_string(64)
  let assert Ok(_) =
    router.handle_request(_, ctx)
    |> wisp_mist.handler(secret_key_base)
    |> mist.new
    |> mist.port(3000)
    |> mist.start

  process.sleep_forever()
}
