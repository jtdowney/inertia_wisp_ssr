import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleam/otp/static_supervisor as supervisor
import gleam/string
import gleam/time/duration
import inertia_wisp/ssr
import inertia_wisp/ssr/internal/pool
import inertia_wisp/ssr/internal/protocol
import simplifile

pub fn default_config_values_test() {
  let config = ssr.default_config("my_app")

  assert config.app_name == "my_app"
  assert config.module_path == "ssr/ssr.js"
  assert config.node_path == None
  assert config.pool_size == 4
  assert config.timeout == duration.seconds(1)
}

pub fn layout_csr_fallback_on_ssr_error_test() {
  let name = process.new_name("ssr_test_fallback")
  let assert Ok(_) = pool.start(name, "test/fixtures/error.js", None, 1)

  let config =
    ssr.SsrConfig(
      ..ssr.default_config("inertia_wisp_ssr"),
      name: name,
      timeout: duration.seconds(1),
      module_path: "test/fixtures/error.js",
    )

  let template = fn(head, body) {
    "<html><head>"
    <> string.join(head, "")
    <> "</head><body>"
    <> body
    <> "</body></html>"
  }

  let render_fn = ssr.layout(config, template)
  let result =
    render_fn("TestComponent", json.object([#("test", json.bool(True))]))

  assert string.contains(result, "id=\"app\"")
  assert string.contains(result, "data-page=\"")
  assert string.contains(result, "<head></head>")
}

pub fn csr_fallback_escapes_xss_chars_test() {
  let name = process.new_name("ssr_test_escape")
  let assert Ok(_) = pool.start(name, "test/fixtures/error.js", None, 1)

  let config =
    ssr.SsrConfig(
      ..ssr.default_config("inertia_wisp_ssr"),
      name: name,
      timeout: duration.seconds(1),
    )

  let template = fn(_head, body) { body }
  let render_fn = ssr.layout(config, template)

  let malicious_data =
    json.object([
      #("xss", json.string("<script>alert('xss')</script>")),
      #("amp", json.string("foo & bar")),
      #("quotes", json.string("\"test\" and 'test'")),
    ])

  let result = render_fn("Evil", malicious_data)

  assert string.contains(result, "&lt;script&gt;")
  assert string.contains(result, "&amp;")
  assert string.contains(result, "&quot;")
  assert string.contains(result, "&#x27;")
  assert !string.contains(result, "<script>")
}

pub fn csr_fallback_empty_head_test() {
  let name = process.new_name("ssr_test_empty_head")
  let assert Ok(_) = pool.start(name, "test/fixtures/error.js", None, 1)

  let config =
    ssr.SsrConfig(
      ..ssr.default_config("inertia_wisp_ssr"),
      name: name,
      timeout: duration.seconds(1),
    )

  let template = fn(head, _body) { "head_count:" <> string.inspect(head) }

  let render_fn = ssr.layout(config, template)
  let result = render_fn("Test", json.object([]))

  assert string.contains(result, "head_count:[]")
}

pub fn make_layout_creates_reusable_closure_test() {
  let name = process.new_name("ssr_test_make_layout")
  let assert Ok(_) = pool.start(name, "test/fixtures/ssr.js", None, 1)

  let config =
    ssr.SsrConfig(
      ..ssr.default_config("inertia_wisp_ssr"),
      name: name,
      timeout: duration.seconds(1),
      module_path: "test/fixtures/ssr.js",
    )

  let layout_factory = ssr.make_layout(config)

  let template1 = fn(_head, body) { "T1:" <> body }
  let template2 = fn(_head, body) { "T2:" <> body }

  let render1 = layout_factory(template1)
  let render2 = layout_factory(template2)

  let page =
    json.object([
      #("component", json.string("Test")),
      #("props", json.object([])),
    ])

  let result1 = render1("Test", page)
  let result2 = render2("Test", page)

  assert string.starts_with(result1, "T1:")
  assert string.starts_with(result2, "T2:")
}

pub fn supervised_starts_pool_test() {
  let assert Ok(cwd) = simplifile.current_directory()
  let name = process.new_name("supervised_test_pool")
  let config =
    ssr.SsrConfig(
      ..ssr.default_config("inertia_wisp_ssr"),
      name: name,
      module_path: cwd <> "/test/fixtures/ssr.js",
      pool_size: 1,
    )

  let assert Ok(_sup) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(ssr.supervised(config))
    |> supervisor.start

  let assert Ok(_page) =
    pool.render(
      name,
      protocol.encode_request(
        json.object([#("component", json.string("Test"))]),
      ),
      duration.seconds(1),
    )
}
