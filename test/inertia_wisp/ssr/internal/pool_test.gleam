import birdie
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import inertia_wisp/ssr/internal/pool
import inertia_wisp/ssr/internal/protocol.{type Page}
import inertia_wisp/ssr/internal/worker
import utils

fn encode_page(page: Page) -> String {
  json.object([
    #("head", json.array(page.head, of: json.string)),
    #("body", json.string(page.body)),
  ])
  |> json.to_string
}

fn make_frame(page_json: json.Json) -> BytesTree {
  protocol.encode_request(page_json)
}

pub fn render_minimal_test() {
  use name <- utils.with_pool("test/fixtures/ssr.js", 1)

  let assert Ok(page) =
    pool.render(
      name,
      make_frame(
        json.object([
          #("component", json.string("TestComponent")),
          #(
            "props",
            json.object([
              #("name", json.string("John Doe")),
              #("age", json.int(40)),
            ]),
          ),
        ]),
      ),
      duration.seconds(1),
    )

  encode_page(page)
  |> birdie.snap("render minimal")
}

pub fn render_malformed_test() {
  use name <- utils.with_pool("test/fixtures/malformed.js", 1)

  let assert Error(pool.Worker(worker.RenderFailed(_))) =
    pool.render(
      name,
      make_frame(
        json.object([
          #("component", json.string("TestComponent")),
          #(
            "props",
            json.object([
              #("name", json.string("John Doe")),
              #("age", json.int(40)),
            ]),
          ),
        ]),
      ),
      duration.seconds(1),
    )
}

pub fn render_timeout_test() {
  use name <- utils.with_pool("test/fixtures/slow.js", 1)

  let assert Error(pool.Worker(worker.Timeout)) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("SlowComponent"))])),
      duration.milliseconds(20),
    )
}

pub fn render_large_response_test() {
  use name <- utils.with_pool("test/fixtures/large.js", 1)

  let assert Ok(page) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("LargeComponent"))])),
      duration.seconds(5),
    )
  assert string.length(page.body) == 10_000
}

pub fn render_pool_not_started_test() {
  let name = process.new_name("nonexistent_pool_xyz")

  let result =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test"))])),
      duration.seconds(1),
    )

  assert result == Error(pool.NotStarted)
}

pub fn render_worker_crashed_test() {
  use name <- utils.with_pool("test/fixtures/crash.js", 1)

  let assert Error(pool.Worker(worker.Crashed)) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test"))])),
      duration.milliseconds(500),
    )
}

pub fn start_with_invalid_node_path_test() {
  let name = process.new_name("inertia_wisp_ssr_bad_node")
  let assert Error(pool.InitFailed) =
    pool.start(
      name,
      "test/fixtures/ssr.js",
      Some("/nonexistent/path/to/node"),
      1,
    )
}

pub fn render_multi_worker_pool_test() {
  use name <- utils.with_pool("test/fixtures/ssr.js", 3)

  let assert Ok(_) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("C1"))])),
      duration.seconds(2),
    )
  let assert Ok(_) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("C2"))])),
      duration.seconds(2),
    )
  let assert Ok(_) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("C3"))])),
      duration.seconds(2),
    )
}

pub fn pool_stop_test() {
  let name = process.new_name("inertia_wisp_ssr_stop_test")
  let assert Ok(_pid) = pool.start(name, "test/fixtures/ssr.js", None, 1)

  let assert Ok(_) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test"))])),
      duration.seconds(1),
    )

  pool.stop(name)

  let assert Error(pool.NotStarted) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test"))])),
      duration.milliseconds(50),
    )
}

pub fn render_pool_saturation_test() {
  use name <- utils.with_pool("test/fixtures/saturation.js", 1)

  let result_subject = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let result =
        pool.render(
          name,
          make_frame(json.object([#("component", json.string("Saturated"))])),
          duration.milliseconds(200),
        )
      process.send(result_subject, result)
    })

  process.sleep(10)

  let assert Error(pool.Timeout) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Fast"))])),
      duration.milliseconds(30),
    )

  let assert Ok(Ok(_)) = process.receive(result_subject, 200)
}

pub fn render_large_valid_payload_test() {
  use name <- utils.with_pool("test/fixtures/large_valid.js", 1)

  let assert Ok(page) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Large"))])),
      duration.seconds(60),
    )

  assert string.length(page.body) > 500_000
}

pub fn crashed_worker_not_reused_test() {
  use name <- utils.with_pool("test/fixtures/crash.js", 1)

  let frame = make_frame(json.object([#("component", json.string("Test"))]))

  let assert Error(pool.Worker(worker.Crashed)) =
    pool.render(name, frame, duration.milliseconds(500))

  let result = pool.render(name, frame, duration.milliseconds(500))
  case result {
    Error(pool.Timeout) -> Nil
    Error(pool.Worker(worker.Crashed)) -> Nil
    other -> {
      let _ = other
      panic as "Expected Timeout or Worker(Crashed)"
    }
  }
}

pub fn render_unicode_props_test() {
  use name <- utils.with_pool("test/fixtures/ssr.js", 1)

  let page_data =
    json.object([
      #("component", json.string("TestComponent")),
      #(
        "props",
        json.object([
          #("emoji", json.string("🎉🚀")),
          #("cjk", json.string("你好世界")),
          #("mixed", json.string("Hello 世界 🌍")),
        ]),
      ),
    ])

  let assert Ok(page) =
    pool.render(name, make_frame(page_data), duration.seconds(2))

  assert string.contains(page.body, "🎉🚀")
  assert string.contains(page.body, "你好世界")
}

pub fn pool_stop_kills_all_workers_test() {
  let name = process.new_name("inertia_wisp_ssr_stop_all")
  let assert Ok(_pid) = pool.start(name, "test/fixtures/ssr.js", None, 3)

  let assert Ok(_) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test"))])),
      duration.seconds(1),
    )

  pool.stop(name)

  let assert Error(pool.NotStarted) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test"))])),
      duration.milliseconds(50),
    )
}

pub fn pool_recovers_worker_on_client_crash_test() {
  use name <- utils.with_pool("test/fixtures/saturation.js", 1)

  let child =
    process.spawn_unlinked(fn() {
      let _ =
        pool.render(
          name,
          make_frame(json.object([#("component", json.string("Slow"))])),
          duration.seconds(5),
        )
      Nil
    })

  process.sleep(20)
  process.kill(child)
  process.sleep(200)

  let assert Ok(_) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test2"))])),
      duration.seconds(2),
    )
}

pub fn pool_handles_waiting_client_crash_test() {
  use name <- utils.with_pool("test/fixtures/saturation.js", 1)

  let result_subject = process.new_subject()

  let _pid1 =
    process.spawn_unlinked(fn() {
      let result =
        pool.render(
          name,
          make_frame(json.object([#("component", json.string("Slow"))])),
          duration.milliseconds(200),
        )
      process.send(result_subject, result)
    })

  process.sleep(10)

  let assert Error(pool.Timeout) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Test"))])),
      duration.milliseconds(30),
    )

  let assert Ok(Ok(_)) = process.receive(result_subject, 500)
  let assert Ok(_) =
    pool.render(
      name,
      make_frame(json.object([#("component", json.string("Final"))])),
      duration.seconds(2),
    )
}
