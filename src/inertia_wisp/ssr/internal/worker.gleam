import child_process.{type Process}
import child_process/stdio
import gleam/bool
import gleam/bytes_tree.{type BytesTree}
import gleam/erlang/application
import gleam/erlang/process.{type Subject, type Timer}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import glisten/internal/handler
import inertia_wisp/ssr/internal/listener
import inertia_wisp/ssr/internal/netstring
import inertia_wisp/ssr/internal/protocol.{type Page}

pub type WorkerError {
  Timeout
  Crashed
  InitFailed
  RenderFailed(String)
}

pub type Worker {
  Worker(
    pool_subject: Subject(WorkerRequest),
    render_fn: fn(BytesTree, Duration) -> Result(Page, WorkerError),
  )
}

pub type WorkerRequest {
  WorkerShutdown
}

pub type WorkerConfig {
  WorkerConfig(
    module_path: String,
    node_path: Option(String),
    start_timeout: Duration,
    listener: Subject(listener.ListenerMessage),
    listener_port: Int,
  )
}

type WorkerMessage {
  PoolRequest(WorkerRequest)
  Render(
    frame: BytesTree,
    timeout: Duration,
    reply_to: Subject(Result(Page, WorkerError)),
  )
  TcpConnected(send: Subject(handler.Message(listener.SenderMessage)))
  TcpData(data: BitArray)
  TcpClosed
  RenderTimeout
  PortExit(code: Int)
}

type PendingRequest {
  PendingRequest(reply_to: Subject(Result(Page, WorkerError)), timer: Timer)
}

type ConnectionState {
  AwaitingConnection
  Connected(
    send: Subject(handler.Message(listener.SenderMessage)),
    pending: Option(PendingRequest),
    buffer: BitArray,
  )
}

type WorkerState {
  WorkerState(
    id: Int,
    self_subject: Subject(WorkerMessage),
    listener_subject: Subject(listener.WorkerMessage),
    node_process: Process,
    connection: ConnectionState,
    process_alive: Bool,
  )
}

fn map_listener_message(msg: listener.WorkerMessage) -> WorkerMessage {
  case msg {
    listener.TcpConnected(send) -> TcpConnected(send)
    listener.TcpData(data) -> TcpData(data)
    listener.TcpClosed -> TcpClosed
  }
}

fn worker_init(
  config: WorkerConfig,
  worker_id: Int,
  script_path: String,
  self_subject: Subject(WorkerMessage),
) {
  let pool_subject_inner: Subject(WorkerRequest) = process.new_subject()
  let listener_subject: Subject(listener.WorkerMessage) = process.new_subject()

  let register_reply = process.new_subject()
  process.send(
    config.listener,
    listener.RegisterWorker(worker_id, listener_subject, register_reply),
  )
  let _ = process.receive(register_reply, 5000)

  use child <- result.try(
    start_node_process(
      self_subject,
      config.node_path,
      script_path,
      config.listener_port,
      config.module_path,
      worker_id,
    )
    |> result.map_error(fn(err) {
      process.send(config.listener, listener.UnregisterWorker(worker_id))
      string.inspect(err)
    }),
  )

  let selector =
    process.new_selector()
    |> process.select(self_subject)
    |> process.select_map(listener_subject, map_listener_message)

  let start_timeout_ms = duration.to_milliseconds(config.start_timeout)
  case process.selector_receive(selector, start_timeout_ms) {
    Ok(TcpConnected(send)) -> {
      let state =
        WorkerState(
          id: worker_id,
          self_subject: self_subject,
          listener_subject: listener_subject,
          node_process: child,
          connection: Connected(send:, pending: None, buffer: <<>>),
          process_alive: True,
        )

      let full_selector =
        process.new_selector()
        |> process.select(self_subject)
        |> process.select_map(pool_subject_inner, fn(msg) { PoolRequest(msg) })
        |> process.select_map(listener_subject, map_listener_message)

      actor.initialised(state)
      |> actor.selecting(full_selector)
      |> actor.returning(#(self_subject, pool_subject_inner))
      |> Ok
    }
    _ -> {
      process.send(config.listener, listener.UnregisterWorker(worker_id))
      child_process.kill(child)
      Error("connection_failed")
    }
  }
}

pub fn start_worker(
  config: WorkerConfig,
  worker_id: Int,
) -> Result(Worker, WorkerError) {
  let priv_dir =
    application.priv_directory("inertia_wisp_ssr") |> result.unwrap("priv")
  let script_path = priv_dir <> "/ssr_server.cjs"

  let start_timeout_ms = duration.to_milliseconds(config.start_timeout)
  case
    actor.new_with_initialiser(start_timeout_ms, worker_init(
      config,
      worker_id,
      script_path,
      _,
    ))
    |> actor.on_message(handle_worker_message)
    |> actor.start
  {
    Ok(started) -> {
      let #(worker_subject, pool_subject) = started.data
      let render_fn = fn(frame: BytesTree, timeout: Duration) {
        worker_render(worker_subject, frame, timeout)
      }
      Ok(Worker(pool_subject:, render_fn:))
    }
    Error(_) -> Error(InitFailed)
  }
}

fn start_node_process(
  worker_subject: Subject(WorkerMessage),
  node_path: Option(String),
  script_path: String,
  server_port: Int,
  module_path: String,
  worker_id: Int,
) -> Result(Process, WorkerError) {
  let builder = case node_path {
    Some(path) -> child_process.new(path)
    None -> child_process.new_with_path("node")
  }

  builder
  |> child_process.arg(script_path)
  |> child_process.arg(int.to_string(server_port))
  |> child_process.arg(module_path)
  |> child_process.arg(int.to_string(worker_id))
  |> child_process.on_exit(fn(code) {
    process.send(worker_subject, PortExit(code))
  })
  |> child_process.stdio(stdio.stream(io.print) |> stdio.capture_stderr)
  |> child_process.spawn()
  |> result.map_error(fn(err) { RenderFailed(string.inspect(err)) })
}

fn handle_worker_message(
  state: WorkerState,
  msg: WorkerMessage,
) -> actor.Next(WorkerState, WorkerMessage) {
  case msg {
    PoolRequest(WorkerShutdown) -> {
      worker_cleanup(state)
      actor.stop()
    }

    Render(frame, timeout, reply_to) -> {
      case state.connection {
        Connected(send:, buffer:, ..) -> {
          let timeout_ms = duration.to_milliseconds(timeout)
          use <- bool.lazy_guard(when: timeout_ms < 1, return: fn() {
            process.send(reply_to, Error(Timeout))
            actor.continue(state)
          })

          let data = bytes_tree.to_bit_array(frame)
          process.send(send, handler.User(listener.WriteToSocket(data)))

          let timer =
            process.send_after(state.self_subject, timeout_ms, RenderTimeout)
          let pending = PendingRequest(reply_to: reply_to, timer: timer)
          let connection = Connected(send:, pending: Some(pending), buffer:)
          actor.continue(WorkerState(..state, connection:))
        }
        AwaitingConnection -> {
          process.send(reply_to, Error(Crashed))
          actor.continue(state)
        }
      }
    }

    TcpConnected(send) -> {
      let connection = Connected(send:, pending: None, buffer: <<>>)
      actor.continue(WorkerState(..state, connection:))
    }

    TcpData(data) -> {
      case state.connection {
        Connected(send:, pending:, buffer:) -> {
          let new_buffer = <<buffer:bits, data:bits>>
          process_buffer(state, send, pending, new_buffer)
        }
        AwaitingConnection -> actor.continue(state)
      }
    }

    TcpClosed -> {
      fail_pending_from_state(state, Crashed)
      // Don't call worker_cleanup here - the Node.js process either:
      // 1. Already exited (causing TCP to close), or
      // 2. Will exit when it detects the closed connection
      // Calling stop on an already-dead process causes a crash.
      actor.stop()
    }

    RenderTimeout -> {
      case state.connection {
        Connected(pending: Some(pending), ..) -> {
          process.send(pending.reply_to, Error(Timeout))
          worker_cleanup(state)
          actor.stop()
        }
        _ -> actor.continue(state)
      }
    }

    PortExit(_code) -> {
      fail_pending_from_state(WorkerState(..state, process_alive: False), Crashed)
      actor.stop()
    }
  }
}

fn process_buffer(
  state: WorkerState,
  send: Subject(handler.Message(listener.SenderMessage)),
  pending: Option(PendingRequest),
  buffer: BitArray,
) -> actor.Next(WorkerState, WorkerMessage) {
  case protocol.decode_response(buffer) {
    Error(protocol.NetstringError(netstring.NeedMore)) -> {
      let connection = Connected(send:, pending:, buffer:)
      actor.continue(WorkerState(..state, connection:))
    }
    Error(_) -> {
      complete_pending(pending, Error(RenderFailed("Protocol error")))
      worker_cleanup(state)
      actor.stop()
    }
    Ok(#(page_result, remaining)) -> {
      let page_result = result.map_error(page_result, protocol_error_to_worker)
      complete_pending(pending, page_result)
      let new_connection = Connected(send:, pending: None, buffer: <<>>)
      process_buffer(
        WorkerState(..state, connection: new_connection),
        send,
        None,
        remaining,
      )
    }
  }
}

fn protocol_error_to_worker(err: protocol.ProtocolError) -> WorkerError {
  case err {
    protocol.RenderError(msg) -> RenderFailed(msg)
    _ -> RenderFailed(string.inspect(err))
  }
}

fn complete_pending(
  pending: Option(PendingRequest),
  result: Result(Page, WorkerError),
) -> Nil {
  case pending {
    Some(req) -> {
      process.cancel_timer(req.timer)
      process.send(req.reply_to, result)
    }
    None -> Nil
  }
}

fn fail_pending_from_state(state: WorkerState, error: WorkerError) -> Nil {
  case state.connection {
    Connected(pending: Some(pending), ..) ->
      complete_pending(Some(pending), Error(error))
    _ -> Nil
  }
}

fn worker_cleanup(state: WorkerState) -> Nil {
  use <- bool.guard(when: !state.process_alive, return: Nil)
  child_process.stop(state.node_process)
}

fn worker_render(
  worker: Subject(WorkerMessage),
  frame: BytesTree,
  timeout: Duration,
) -> Result(Page, WorkerError) {
  let timeout_ms = duration.to_milliseconds(timeout)

  // Timeout must be at least 1ms for process.receive
  case timeout_ms {
    ms if ms < 1 -> Error(Timeout)
    _ -> {
      let reply_subject = process.new_subject()
      process.send(worker, Render(frame, timeout, reply_subject))

      case process.receive(reply_subject, timeout_ms) {
        Ok(result) -> result
        Error(_) -> Error(Timeout)
      }
    }
  }
}
