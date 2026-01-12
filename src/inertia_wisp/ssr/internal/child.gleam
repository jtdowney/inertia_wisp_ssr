import child_process.{type Process}
import child_process/stdio
import gleam/erlang/application
import gleam/erlang/process.{type Pid}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}
import inertia_wisp/ssr/internal/protocol.{type Page}

pub opaque type Child {
  Child(process: Process)
}

pub type ChunkResult {
  Complete(result: Result(Page, String), remaining: StringTree)
  Incomplete(buffer: StringTree)
}

pub fn start(
  module_path: String,
  node_path: Option(String),
  callback_pid: Pid,
) -> Result(Child, String) {
  let server_script = get_server_script_path()

  let builder = case node_path {
    option.None -> child_process.new_with_path("node")
    option.Some(path) -> child_process.new(path)
  }

  let process_result =
    builder
    |> child_process.arg(server_script)
    |> child_process.arg(module_path)
    |> child_process.stdio(
      stdio.stream(fn(chunk) { send_child_data(callback_pid, chunk) }),
    )
    |> child_process.on_exit(fn(code) { send_child_exit(callback_pid, code) })
    |> child_process.spawn()

  case process_result {
    Ok(proc) -> Ok(Child(proc))
    Error(child_process.FileNotFound(_path)) -> Error("node_not_found")
    Error(child_process.FileNotExecutable(_path)) ->
      Error("node_not_executable")
    Error(child_process.SystemLimit) -> Error("system_limit")
  }
}

pub fn write_request(child: Child, page_data: Json) -> Nil {
  let request = protocol.encode_request(page_data)
  child_process.write(child.process, request)
}

pub fn decode_chunk(buffer: StringTree, chunk: String) -> ChunkResult {
  case string.contains(chunk, "\n") {
    False -> Incomplete(buffer: string_tree.append(buffer, chunk))
    True ->
      buffer
      |> string_tree.append(chunk)
      |> string_tree.to_string()
      |> process_lines()
  }
}

fn process_lines(data: String) -> ChunkResult {
  case string.split_once(data, "\n") {
    Ok(#(line, rest)) -> {
      case protocol.decode_response(line) {
        Ok(page) ->
          Complete(result: Ok(page), remaining: string_tree.from_string(rest))
        Error(protocol.NotProtocolLine) -> process_lines(rest)
        Error(protocol.InvalidJson(reason)) ->
          Complete(
            result: Error("invalid response: " <> reason),
            remaining: string_tree.from_string(rest),
          )
        Error(protocol.RenderError(reason)) ->
          Complete(
            result: Error("render error: " <> reason),
            remaining: string_tree.from_string(rest),
          )
      }
    }
    Error(Nil) -> Incomplete(buffer: string_tree.from_string(data))
  }
}

pub fn stop(child: Child) -> Nil {
  child_process.close(child.process)
}

fn get_server_script_path() -> String {
  let priv_dir =
    application.priv_directory("inertia_wisp_ssr") |> result.unwrap("priv")
  priv_dir <> "/ssr-server.cjs"
}

@external(erlang, "inertia_wisp_ssr_ffi", "send_child_data")
fn send_child_data(pid: Pid, chunk: String) -> Nil

@external(erlang, "inertia_wisp_ssr_ffi", "send_child_exit")
fn send_child_exit(pid: Pid, code: Int) -> Nil
