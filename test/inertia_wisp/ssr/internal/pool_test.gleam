import birdie
import gleam/erlang/atom
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import inertia_wisp/ssr/internal/pool
import inertia_wisp/ssr/internal/protocol.{type Page}

fn encode_page(page: Page) -> String {
  json.object([
    #("head", json.array(page.head, of: json.string)),
    #("body", json.string(page.body)),
  ])
  |> json.to_string
}

pub fn render_minimal_test() {
  let name = atom.create("inertia_wisp_ssr")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/ssr.js", None, 1, 0, 1_048_576)
  let assert Ok(page) =
    pool.render(
      name,
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
      duration.seconds(1),
    )

  encode_page(page)
  |> birdie.snap("render minimal")
}

pub fn render_malformed_test() {
  let name = atom.create("inertia_wisp_ssr_malformed")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/malformed.js", None, 1, 0, 1_048_576)
  let assert Error(pool.WorkerError(_)) =
    pool.render(
      name,
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
      duration.seconds(1),
    )
}

pub fn render_timeout_test() {
  let name = atom.create("inertia_wisp_ssr_timeout")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/slow.js", None, 1, 0, 1_048_576)
  let assert Error(pool.WorkerTimeout) =
    pool.render(
      name,
      json.object([#("component", json.string("SlowComponent"))]),
      duration.milliseconds(100),
    )
}

pub fn render_buffer_overflow_test() {
  let name = atom.create("inertia_wisp_ssr_overflow")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/large.js", None, 1, 0, 100)
  let assert Error(pool.BufferOverflow) =
    pool.render(
      name,
      json.object([#("component", json.string("LargeComponent"))]),
      duration.seconds(5),
    )
}

pub fn render_pool_not_started_test() {
  let name = atom.create("nonexistent_pool_xyz")

  let result =
    pool.render(
      name,
      json.object([#("component", json.string("Test"))]),
      duration.seconds(1),
    )

  assert result == Error(pool.PoolNotStarted)
}

pub fn render_worker_crashed_test() {
  let name = atom.create("inertia_wisp_ssr_crash")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/crash.js", None, 1, 0, 1_048_576)

  let assert Error(pool.WorkerCrashed) =
    pool.render(
      name,
      json.object([#("component", json.string("Test"))]),
      duration.seconds(2),
    )
}

pub fn render_with_console_noise_test() {
  let name = atom.create("inertia_wisp_ssr_noisy")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/noisy.js", None, 1, 0, 1_048_576)

  let assert Ok(page) =
    pool.render(
      name,
      json.object([#("component", json.string("NoisyComponent"))]),
      duration.seconds(2),
    )

  assert page.body == "<div>noisy</div>"
  assert page.head == ["<title>Noisy</title>"]
}

pub fn start_with_invalid_node_path_test() {
  let name = atom.create("inertia_wisp_ssr_bad_node")
  let assert Error(pool.InitFailed) =
    pool.start(
      name,
      "test/fixtures/ssr.js",
      Some("/nonexistent/path/to/node"),
      1,
      0,
      1_048_576,
    )
}

pub fn render_multi_worker_pool_test() {
  let name = atom.create("inertia_wisp_ssr_multi_worker")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/ssr.js", None, 3, 0, 1_048_576)

  let assert Ok(_) =
    pool.render(
      name,
      json.object([#("component", json.string("C1"))]),
      duration.seconds(2),
    )
  let assert Ok(_) =
    pool.render(
      name,
      json.object([#("component", json.string("C2"))]),
      duration.seconds(2),
    )
  let assert Ok(_) =
    pool.render(
      name,
      json.object([#("component", json.string("C3"))]),
      duration.seconds(2),
    )
}

pub fn render_with_overflow_config_test() {
  let name = atom.create("inertia_wisp_ssr_overflow_config")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/ssr.js", None, 1, 2, 1_048_576)

  let assert Ok(_) =
    pool.render(
      name,
      json.object([#("component", json.string("O1"))]),
      duration.seconds(2),
    )
  let assert Ok(_) =
    pool.render(
      name,
      json.object([#("component", json.string("O2"))]),
      duration.seconds(2),
    )
}

pub fn pool_stop_test() {
  let name = atom.create("inertia_wisp_ssr_stop_test")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/ssr.js", None, 1, 0, 1_048_576)

  let assert Ok(_) =
    pool.render(
      name,
      json.object([#("component", json.string("Test"))]),
      duration.seconds(1),
    )

  pool.stop(name)

  let assert Error(pool.PoolNotStarted) =
    pool.render(
      name,
      json.object([#("component", json.string("Test"))]),
      duration.seconds(1),
    )
}

pub fn render_pool_saturation_test() {
  let name = atom.create("inertia_wisp_ssr_saturation")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/slow.js", None, 1, 0, 1_048_576)

  let result_subject = process.new_subject()

  let _pid =
    process.spawn(fn() {
      let result =
        pool.render(
          name,
          json.object([#("component", json.string("Slow"))]),
          duration.seconds(2),
        )
      process.send(result_subject, result)
    })

  process.sleep(50)

  let assert Error(pool.WorkerTimeout) =
    pool.render(
      name,
      json.object([#("component", json.string("Fast"))]),
      duration.milliseconds(100),
    )

  let assert Ok(Ok(_)) = process.receive(result_subject, 2000)
  pool.stop(name)
}

pub fn render_large_valid_payload_test() {
  let name = atom.create("inertia_wisp_ssr_large_valid")
  let assert Ok(_pid) =
    pool.start(name, "test/fixtures/large_valid.js", None, 1, 0, 1_048_576)

  let assert Ok(page) =
    pool.render(
      name,
      json.object([#("component", json.string("Large"))]),
      duration.seconds(5),
    )

  assert string.length(page.body) > 500_000
  pool.stop(name)
}
