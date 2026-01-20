import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/time/duration.{type Duration}
import inertia_wisp/ssr/internal/protocol.{type Page}

pub type PoolError {
  BufferOverflow
  InitFailed
  PoolNotStarted
  WorkerCrashed
  WorkerError(String)
  WorkerExit(String)
  WorkerTimeout
}

@external(erlang, "inertia_wisp_ssr_ffi", "start_pool")
pub fn start(
  name: Atom,
  module_path: String,
  node_path: Option(String),
  pool_size: Int,
  max_overflow: Int,
  max_buffer_size: Int,
) -> Result(Pid, PoolError)

@external(erlang, "inertia_wisp_ssr_ffi", "stop_pool")
pub fn stop(pool_name: Atom) -> Nil

@external(erlang, "inertia_wisp_ssr_ffi", "render")
fn do_render(
  pool_name: Atom,
  page_data: Json,
  timeout: Int,
) -> Result(Page, PoolError)

pub fn render(
  pool_name: Atom,
  page_data: Json,
  timeout: Duration,
) -> Result(Page, PoolError) {
  let timeout = duration.to_milliseconds(timeout)
  do_render(pool_name, page_data, timeout)
}
