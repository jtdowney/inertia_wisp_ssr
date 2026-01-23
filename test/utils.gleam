import gleam/erlang/process
import gleam/option.{type Option, None}
import inertia_wisp/ssr/internal/pool

@external(erlang, "inertia_wisp_ssr_test_ffi", "suppress_logger")
pub fn suppress_logger() -> Nil

pub fn with_pool(
  module_path: String,
  pool_size: Int,
  callback: fn(pool.PoolName) -> a,
) -> a {
  with_pool_options(module_path, None, pool_size, callback)
}

pub fn with_pool_options(
  module_path: String,
  node_path: Option(String),
  pool_size: Int,
  callback: fn(pool.PoolName) -> a,
) -> a {
  let name = process.new_name("test_pool")
  let assert Ok(_) = pool.start(name, module_path, node_path, pool_size)
  let result = callback(name)
  pool.stop(name)
  result
}
