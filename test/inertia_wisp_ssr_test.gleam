import gleam/erlang/atom
import gleeunit

pub fn main() {
  set_log_level_error()
  gleeunit.main()
}

fn set_log_level_error() -> Nil {
  let level_key = atom.create("level")
  let error_level = atom.create("error")
  let _ = logger_set_primary_config(level_key, error_level)
  Nil
}

@external(erlang, "logger", "set_primary_config")
fn logger_set_primary_config(key: atom.Atom, value: atom.Atom) -> atom.Atom
