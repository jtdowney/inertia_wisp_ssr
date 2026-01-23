import esgleam
import simplifile

pub fn main() {
  let assert Ok(_) =
    esgleam.new("../priv")
    |> esgleam.kind(esgleam.Script)
    |> esgleam.format(esgleam.Cjs)
    |> esgleam.platform(esgleam.Node)
    |> esgleam.entry("ssr_server.gleam")
    |> esgleam.bundle

  let assert Ok(_) =
    simplifile.rename("../priv/ssr_server.js", "../priv/ssr_server.cjs")
}
