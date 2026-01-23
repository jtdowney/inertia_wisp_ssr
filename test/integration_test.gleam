/// Integration tests that verify the full SSR flow works with per-worker TCP listeners.
///
/// These tests exercise the complete path:
/// 1. Each worker starts its own glisten TCP listener
/// 2. Workers spawn Node.js running priv/ssr_server.js
/// 3. Node connects directly to its worker's listener
/// 4. Communication uses netstring-framed JSON
/// 5. Responses are properly parsed and returned to the caller
import birdie
import gleam/json
import gleam/string
import gleam/time/duration
import inertia_wisp/ssr/internal/pool
import inertia_wisp/ssr/internal/protocol.{Page}
import utils

/// Test the full SSR render flow using the test_render.js fixture
pub fn full_ssr_render_test() {
  use pool_name <- utils.with_pool("test/fixtures/test_render.js", 1)

  let page_data =
    json.object([
      #("component", json.string("TestComponent")),
      #("props", json.object([#("message", json.string("Hello"))])),
      #("url", json.string("/")),
      #("version", json.string("1.0")),
    ])

  let assert Ok(Page(head, body)) =
    pool.render(pool_name, page_data, duration.seconds(5))

  assert head == ["<title>TestComponent</title>"]
  assert string.contains(body, "\"message\":\"Hello\"")
  assert string.contains(body, "id=\"app\"")
}

/// Test that SSR properly handles component name in the rendered output
pub fn ssr_renders_component_name_test() {
  use pool_name <- utils.with_pool("test/fixtures/test_render.js", 1)

  let page_data =
    json.object([
      #("component", json.string("Dashboard")),
      #("props", json.object([])),
    ])

  let assert Ok(Page(head, _body)) =
    pool.render(pool_name, page_data, duration.seconds(5))

  assert head == ["<title>Dashboard</title>"]
}

/// Test that props are properly serialized and included in the body
pub fn ssr_serializes_props_test() {
  use pool_name <- utils.with_pool("test/fixtures/test_render.js", 1)

  let page_data =
    json.object([
      #("component", json.string("UserProfile")),
      #(
        "props",
        json.object([
          #("name", json.string("Alice")),
          #("age", json.int(30)),
          #("active", json.bool(True)),
        ]),
      ),
    ])

  let assert Ok(Page(_head, body)) =
    pool.render(pool_name, page_data, duration.seconds(5))

  body
  |> birdie.snap("ssr serializes props")
}

/// Test multiple sequential renders work correctly
pub fn ssr_multiple_renders_test() {
  use pool_name <- utils.with_pool("test/fixtures/test_render.js", 1)

  let page1 =
    json.object([
      #("component", json.string("Page1")),
      #("props", json.object([#("id", json.int(1))])),
    ])
  let assert Ok(Page(head1, _body1)) =
    pool.render(pool_name, page1, duration.seconds(5))
  assert head1 == ["<title>Page1</title>"]

  let page2 =
    json.object([
      #("component", json.string("Page2")),
      #("props", json.object([#("id", json.int(2))])),
    ])
  let assert Ok(Page(head2, _body2)) =
    pool.render(pool_name, page2, duration.seconds(5))
  assert head2 == ["<title>Page2</title>"]

  let page3 =
    json.object([
      #("component", json.string("Page3")),
      #("props", json.object([#("id", json.int(3))])),
    ])
  let assert Ok(Page(head3, _body3)) =
    pool.render(pool_name, page3, duration.seconds(5))
  assert head3 == ["<title>Page3</title>"]
}
