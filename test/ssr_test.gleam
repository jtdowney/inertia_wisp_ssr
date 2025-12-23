import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/string
import gleeunit/should
import inertia_wisp_ssr
import inertia_wisp_ssr/internal/protocol
import inertia_wisp_ssr/internal/worker

pub fn decode_valid_ssr_success_test() {
  let line =
    "ISSR{\"ok\":true,\"head\":[\"<title>Test</title>\"],\"body\":\"<div>Hello</div>\"}\n"
  let result = protocol.decode_response(line)

  result
  |> should.be_ok
  |> should.equal(protocol.SsrSuccess(
    head: ["<title>Test</title>"],
    body: "<div>Hello</div>",
  ))
}

pub fn decode_valid_ssr_error_test() {
  let line = "ISSR{\"ok\":false,\"error\":\"render failed\"}\n"
  let result = protocol.decode_response(line)

  result
  |> should.be_ok
  |> should.equal(protocol.SsrRenderError(error: "render failed"))
}

pub fn decode_empty_head_test() {
  let line = "ISSR{\"ok\":true,\"head\":[],\"body\":\"<div>Empty</div>\"}\n"
  let result = protocol.decode_response(line)

  result
  |> should.be_ok
  |> should.equal(protocol.SsrSuccess(head: [], body: "<div>Empty</div>"))
}

pub fn decode_multiple_head_elements_test() {
  let line =
    "ISSR{\"ok\":true,\"head\":[\"<title>Page</title>\",\"<meta name=\\\"desc\\\">\"],\"body\":\"<div></div>\"}\n"
  let result = protocol.decode_response(line)

  result
  |> should.be_ok
  |> should.equal(protocol.SsrSuccess(
    head: ["<title>Page</title>", "<meta name=\"desc\">"],
    body: "<div></div>",
  ))
}

pub fn decode_non_protocol_line_test() {
  let line = "console.log output\n"
  let result = protocol.decode_response(line)

  result |> should.be_error
  let assert Error(protocol.NotProtocolLine) = result
}

pub fn decode_malformed_json_test() {
  let line = "ISSR{invalid json}\n"
  let result = protocol.decode_response(line)

  result |> should.be_error
  let assert Error(protocol.InvalidJson(_)) = result
}

pub fn default_config_values_test() {
  let config = inertia_wisp_ssr.default_config()

  config.module_path |> should.equal("priv/ssr/ssr.js")
  config.pool_size |> should.equal(4)
  config.max_overflow |> should.equal(2)
  config.timeout |> should.equal(5000)
}

pub fn custom_config_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("custom_test"),
      module_path: "build/ssr.js",
      pool_size: 8,
      max_overflow: 4,
      timeout: 10_000,
    )

  config.module_path |> should.equal("build/ssr.js")
  config.pool_size |> should.equal(8)
  config.max_overflow |> should.equal(4)
  config.timeout |> should.equal(10_000)
}

pub fn worker_renders_ssr_test() {
  let assert Ok(w) = worker.start("test/fixtures/ssr.js")

  let page_data =
    json.object([
      #("component", json.string("HomePage")),
      #("props", json.object([#("name", json.string("John"))])),
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
  string.contains(body, "HomePage") |> should.equal(True)
  string.contains(body, "John") |> should.equal(True)

  worker.stop(w)
}

pub fn worker_handles_error_test() {
  let assert Ok(w) = worker.start("test/fixtures/malformed.js")

  let page_data =
    json.object([
      #("component", json.string("Test")),
      #("props", json.object([])),
      #("url", json.string("/")),
    ])
  let result = worker.call(w, page_data, 5000)

  case result {
    Ok(protocol.SsrRenderError(_)) -> Nil
    Error(_) -> Nil
    Ok(protocol.SsrSuccess(_, _)) -> panic as "Expected error but got success"
  }

  worker.stop(w)
}

pub fn pool_renders_ssr_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("pool_renders_ssr_test"),
      module_path: "test/fixtures/ssr.js",
      pool_size: 2,
      max_overflow: 0,
      timeout: 5000,
    )

  let child_spec = inertia_wisp_ssr.child_spec(config)
  let assert Ok(started) = child_spec.start()

  let template = fn(head: List(String), body: String) -> String {
    let head_html = string.join(head, "\n")
    "<!DOCTYPE html><html><head>"
    <> head_html
    <> "</head><body>"
    <> body
    <> "</body></html>"
  }

  let layout_fn = inertia_wisp_ssr.layout(config, template)
  let page_data =
    json.object([
      #("component", json.string("TestPage")),
      #("props", json.object([#("greeting", json.string("Hello"))])),
      #("url", json.string("/test")),
    ])

  let result = layout_fn("TestPage", page_data)

  string.contains(result, "<title>TestPage</title>") |> should.equal(True)
  string.contains(result, "data-component=\"TestPage\"") |> should.equal(True)
  string.contains(result, "data-page=") |> should.equal(False)

  process.send_exit(started.pid)
}

pub fn make_layout_renders_ssr_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("make_layout_renders_ssr_test"),
      module_path: "test/fixtures/ssr.js",
      pool_size: 2,
      max_overflow: 0,
      timeout: 5000,
    )

  let child_spec = inertia_wisp_ssr.child_spec(config)
  let assert Ok(started) = child_spec.start()

  let layout = inertia_wisp_ssr.make_layout(config)

  let template = fn(head: List(String), body: String) -> String {
    let head_html = string.join(head, "\n")
    "<!DOCTYPE html><html><head>"
    <> head_html
    <> "</head><body>"
    <> body
    <> "</body></html>"
  }

  let layout_fn = layout(template)
  let page_data =
    json.object([
      #("component", json.string("AboutPage")),
      #("props", json.object([#("version", json.string("1.0"))])),
      #("url", json.string("/about")),
    ])

  let result = layout_fn("AboutPage", page_data)

  string.contains(result, "<title>AboutPage</title>") |> should.equal(True)
  string.contains(result, "data-component=\"AboutPage\"") |> should.equal(True)
  string.contains(result, "data-page=") |> should.equal(False)

  process.send_exit(started.pid)
}

pub fn layout_fallback_contains_data_page_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("layout_fallback_contains_data_page_test"),
      module_path: "test/fixtures/malformed.js",
      pool_size: 1,
      max_overflow: 0,
      timeout: 5000,
    )

  let child_spec = inertia_wisp_ssr.child_spec(config)
  let assert Ok(started) = child_spec.start()

  let template = fn(head: List(String), body: String) -> String {
    let head_html = string.join(head, "")
    "<html><head>" <> head_html <> "</head><body>" <> body <> "</body></html>"
  }

  let layout_fn = inertia_wisp_ssr.layout(config, template)
  let page_data = json.object([#("name", json.string("Test"))])
  let result = layout_fn("TestComponent", page_data)

  string.contains(result, "data-page=") |> should.equal(True)
  string.contains(result, "id=\"app\"") |> should.equal(True)

  process.send_exit(started.pid)
}

pub fn layout_fallback_escapes_json_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("layout_fallback_escapes_json_test"),
      module_path: "test/fixtures/malformed.js",
      pool_size: 1,
      max_overflow: 0,
      timeout: 5000,
    )

  let child_spec = inertia_wisp_ssr.child_spec(config)
  let assert Ok(started) = child_spec.start()

  let template = fn(_head: List(String), body: String) -> String { body }

  let layout_fn = inertia_wisp_ssr.layout(config, template)
  let page_data =
    json.object([#("html", json.string("<script>alert(1)</script>"))])
  let result = layout_fn("Test", page_data)

  string.contains(result, "&lt;script&gt;") |> should.equal(True)
  string.contains(result, "<script>alert(1)</script>") |> should.equal(False)

  process.send_exit(started.pid)
}

pub fn layout_fallback_empty_head_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("layout_fallback_empty_head_test"),
      module_path: "test/fixtures/malformed.js",
      pool_size: 1,
      max_overflow: 0,
      timeout: 5000,
    )

  let child_spec = inertia_wisp_ssr.child_spec(config)
  let assert Ok(started) = child_spec.start()

  let head_received = fn(head: List(String), _body: String) -> String {
    case head {
      [] -> "empty"
      _ -> "not-empty"
    }
  }

  let layout_fn = inertia_wisp_ssr.layout(config, head_received)
  let page_data = json.object([])
  let result = layout_fn("Test", page_data)

  result |> should.equal("empty")

  process.send_exit(started.pid)
}

pub fn pool_not_started_returns_error_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("nonexistent_pool_test"),
      module_path: "test/fixtures/ssr.js",
      pool_size: 1,
      max_overflow: 0,
      timeout: 100,
    )

  let template = fn(_head: List(String), body: String) -> String { body }
  let layout_fn = inertia_wisp_ssr.layout(config, template)
  let page_data = json.object([#("test", json.string("data"))])
  let result = layout_fn("Test", page_data)

  string.contains(result, "data-page=") |> should.equal(True)
}

pub fn render_timeout_fallback_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("render_timeout_fallback_test"),
      module_path: "test/fixtures/slow.js",
      pool_size: 1,
      max_overflow: 0,
      timeout: 50,
    )

  let child_spec = inertia_wisp_ssr.child_spec(config)
  let assert Ok(started) = child_spec.start()

  let template = fn(_head: List(String), body: String) -> String { body }
  let layout_fn = inertia_wisp_ssr.layout(config, template)
  let page_data = json.object([#("test", json.string("timeout"))])
  let result = layout_fn("SlowComponent", page_data)

  string.contains(result, "data-page=") |> should.equal(True)
  string.contains(result, "id=\"app\"") |> should.equal(True)

  process.send_exit(started.pid)
}

pub fn checkout_timeout_fallback_test() {
  let config =
    inertia_wisp_ssr.SsrConfig(
      name: atom.create("checkout_timeout_fallback_test"),
      module_path: "test/fixtures/slow.js",
      pool_size: 1,
      max_overflow: 0,
      timeout: 50,
    )

  let child_spec = inertia_wisp_ssr.child_spec(config)
  let assert Ok(started) = child_spec.start()

  let template = fn(_head: List(String), body: String) -> String { body }
  let layout_fn = inertia_wisp_ssr.layout(config, template)
  let page_data = json.object([#("test", json.string("checkout"))])

  process.spawn(fn() {
    layout_fn("SlowComponent", page_data)
    Nil
  })

  process.sleep(10)

  let result = layout_fn("BlockedComponent", page_data)

  string.contains(result, "data-page=") |> should.equal(True)
  string.contains(result, "id=\"app\"") |> should.equal(True)

  process.send_exit(started.pid)
}
