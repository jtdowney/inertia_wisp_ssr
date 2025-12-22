import gleam/json
import gleeunit/should
import inertia_wisp_ssr/internal/protocol
import inertia_wisp_ssr/internal/worker

pub fn start_and_call_worker_test() {
  let assert Ok(w) = worker.start("test/fixtures/ssr.js")

  let page_data =
    json.object([
      #("component", json.string("HomePage")),
      #("props", json.object([#("name", json.string("Test"))])),
      #("url", json.string("/")),
    ])

  let result = worker.call(w, page_data, 5000)
  result |> should.be_ok

  let assert Ok(protocol.SsrSuccess(head, body)) = result
  head
  |> should.equal([
    "<title>HomePage</title>",
    "<meta name=\"test\" content=\"true\">",
  ])

  body
  |> should.equal(
    "<div id=\"app\" data-component=\"HomePage\">{\"name\":\"Test\"}</div>",
  )

  worker.stop(w)
}

pub fn worker_handles_render_error_test() {
  let assert Ok(w) = worker.start("test/fixtures/malformed.js")

  let page_data = json.object([#("component", json.string("Test"))])

  let result = worker.call(w, page_data, 5000)

  result |> should.be_ok

  let assert Ok(protocol.SsrRenderError(_error)) = result

  worker.stop(w)
}
