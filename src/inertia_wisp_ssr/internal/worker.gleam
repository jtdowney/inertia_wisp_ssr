import child_process
import child_process/stdio
import gleam/erlang/application
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import inertia_wisp_ssr/internal/protocol.{type SsrResult}

/// Opaque worker handle
pub opaque type Worker {
  Worker(subject: Subject(Message))
}

/// Messages handled by the worker actor
type Message {
  Call(page_data: json.Json, reply_to: Subject(Result(SsrResult, String)))
  Response(line: String)
  ProcessExited(code: Int)
  Shutdown
}

/// Internal actor state
type State {
  State(
    process: child_process.Process,
    pending: Option(Subject(Result(SsrResult, String))),
    buffer: String,
  )
}

fn get_server_script_path() -> String {
  let priv_dir =
    application.priv_directory("inertia_wisp_ssr") |> result.unwrap("priv")
  priv_dir <> "/ssr-server.cjs"
}

/// Start a new worker managing a Node.js process
pub fn start(module_path: String) -> Result(Worker, String) {
  let init_result =
    actor.new_with_initialiser(5000, fn(actor_subject) {
      init(actor_subject, module_path)
    })
    |> actor.on_message(handle_message)
    |> actor.start

  case init_result {
    Ok(started) -> Ok(Worker(started.data))
    Error(actor.InitTimeout) -> Error("timeout")
    Error(actor.InitFailed(reason)) -> Error(reason)
    Error(actor.InitExited(_reason)) -> Error("worker init exited")
  }
}

fn init(
  actor_subject: Subject(Message),
  module_path: String,
) -> Result(actor.Initialised(State, Message, Subject(Message)), String) {
  let server_script = get_server_script_path()

  let process_result =
    child_process.new_with_path("node")
    |> child_process.arg(server_script)
    |> child_process.arg(module_path)
    |> child_process.stdio(
      stdio.stream(fn(chunk) { process.send(actor_subject, Response(chunk)) }),
    )
    |> child_process.on_exit(fn(code) {
      process.send(actor_subject, ProcessExited(code))
    })
    |> child_process.spawn()

  case process_result {
    Ok(proc) -> {
      let state = State(process: proc, pending: None, buffer: "")

      actor.initialised(state)
      |> actor.returning(actor_subject)
      |> Ok
    }
    Error(child_process.FileNotFound(_path)) -> Error("node_not_found")
    Error(child_process.FileNotExecutable(_path)) ->
      Error("node_not_executable")
    Error(child_process.SystemLimit) -> Error("system_limit")
  }
}

fn handle_message(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Call(page_data, reply_to) -> handle_call(page_data, reply_to, state)
    Response(chunk) -> handle_chunk(chunk, state)
    ProcessExited(_code) -> handle_exit(state)
    Shutdown -> handle_shutdown(state)
  }
}

/// Process a chunk of data, splitting on newlines and handling each complete line
fn handle_chunk(chunk: String, state: State) -> actor.Next(State, Message) {
  let data = state.buffer <> chunk
  process_lines(data, state)
}

/// Split data on newlines and process complete lines
fn process_lines(data: String, state: State) -> actor.Next(State, Message) {
  case string.split_once(data, "\n") {
    Ok(#(line, rest)) -> {
      let new_state = process_line(line, state)
      process_lines(rest, new_state)
    }
    Error(Nil) -> actor.continue(State(..state, buffer: data))
  }
}

fn process_line(line: String, state: State) -> State {
  case protocol.decode_response(line) {
    Ok(result) ->
      case state.pending {
        Some(reply_to) -> {
          process.send(reply_to, Ok(result))
          State(..state, pending: None, buffer: "")
        }
        None -> state
      }
    Error(protocol.NotProtocolLine) -> state
    Error(protocol.InvalidJson(reason)) ->
      case state.pending {
        Some(reply_to) -> {
          process.send(reply_to, Error("invalid response: " <> reason))
          State(..state, pending: None, buffer: "")
        }
        None -> state
      }
  }
}

fn handle_call(
  page_data: json.Json,
  reply_to: Subject(Result(SsrResult, String)),
  state: State,
) -> actor.Next(State, Message) {
  let request = protocol.encode_request(page_data)
  child_process.write(state.process, request)
  actor.continue(State(..state, pending: Some(reply_to)))
}

fn handle_exit(state: State) -> actor.Next(State, Message) {
  case state.pending {
    Some(reply_to) -> process.send(reply_to, Error("process exited"))
    None -> Nil
  }
  actor.stop()
}

fn handle_shutdown(state: State) -> actor.Next(State, Message) {
  child_process.stop(state.process)
  actor.stop()
}

/// Call the worker to render a page
pub fn call(
  worker: Worker,
  page_data: json.Json,
  timeout: Int,
) -> Result(SsrResult, String) {
  let reply_subject = process.new_subject()
  process.send(worker.subject, Call(page_data, reply_subject))

  case process.receive(reply_subject, timeout) {
    Ok(result) -> result
    Error(Nil) -> Error("timeout")
  }
}

/// Stop the worker and its Node.js process
pub fn stop(worker: Worker) -> Nil {
  process.send(worker.subject, Shutdown)
}
