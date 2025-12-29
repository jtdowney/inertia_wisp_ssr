//// Internal module for poolboy integration via FFI.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/json
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import inertia_wisp_ssr/internal/protocol.{type SsrResult}

/// Error types for pool operations
pub type PoolError {
  /// Timed out waiting to checkout a worker from the pool
  CheckoutTimeout
  /// Timed out waiting for the worker to render
  RenderTimeout
  /// Pool process is not running
  PoolNotStarted
  /// Worker process crashed
  WorkerCrashed
  /// Worker's internal render timeout
  WorkerTimeout
  /// Generic pool error
  PoolError
  /// Worker returned an error with a reason
  WorkerError(String)
}

/// FFI: Start poolboy pool with prepared args
@external(erlang, "inertia_wisp_ssr_poolboy_ffi", "start_pool")
fn ffi_start_pool(
  name: Atom,
  module_path: String,
  pool_size: Int,
  max_overflow: Int,
) -> Result(Pid, Dynamic)

/// FFI: Render via pool (handles checkout/checkin)
@external(erlang, "inertia_wisp_ssr_poolboy_ffi", "render")
fn ffi_render(
  pool_name: Atom,
  page_data: json.Json,
  timeout: Int,
) -> Result(SsrResult, Dynamic)

/// Create a child specification for adding the pool to a supervision tree.
pub fn supervised(
  name: Atom,
  module_path: String,
  pool_size: Int,
  max_overflow: Int,
) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    case ffi_start_pool(name, module_path, pool_size, max_overflow) {
      Ok(pid) -> Ok(actor.Started(pid, Nil))
      Error(_reason) -> Error(actor.InitFailed("poolboy start failed"))
    }
  })
}

/// Render a page using a worker from the pool.
/// Handles checkout with blocking wait, render call, and checkin.
pub fn render(
  pool_name: Atom,
  page_data: json.Json,
  timeout: Int,
) -> Result(SsrResult, PoolError) {
  case ffi_render(pool_name, page_data, timeout) {
    Ok(result) -> Ok(result)
    Error(err) -> Error(decode_pool_error(err))
  }
}

fn decode_pool_error(err: Dynamic) -> PoolError {
  case decode.run(err, atom.decoder()) {
    Ok(error_atom) -> atom_to_pool_error(error_atom)
    Error(_) ->
      case decode.run(err, worker_error_decoder()) {
        Ok(reason) -> WorkerError(reason)
        Error(_) -> PoolError
      }
  }
}

fn atom_to_pool_error(error_atom: Atom) -> PoolError {
  case atom.to_string(error_atom) {
    "checkout_timeout" -> CheckoutTimeout
    "render_timeout" -> RenderTimeout
    "pool_not_started" -> PoolNotStarted
    "worker_crashed" -> WorkerCrashed
    "worker_timeout" -> WorkerTimeout
    "pool_error" -> PoolError
    "render_error" -> PoolError
    _ -> PoolError
  }
}

fn worker_error_decoder() -> decode.Decoder(String) {
  let worker_error_atom = atom.create("worker_error")
  use tag <- decode.field(0, atom.decoder())
  use reason <- decode.field(1, decode.string)
  case tag == worker_error_atom {
    True -> decode.success(reason)
    False -> decode.failure(reason, "Expected 'worker_error' tag")
  }
}
