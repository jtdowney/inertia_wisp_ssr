import unitest

@external(erlang, "inertia_wisp_ssr_test_ffi", "suppress_logger")
fn suppress_logger() -> Nil

pub fn main() {
  suppress_logger()
  unitest.main()
}
