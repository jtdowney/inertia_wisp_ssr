import gleam/bytes_tree.{type BytesTree}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None}
import gleam/otp/actor
import gleam/result
import gleam/string
import glisten.{type Connection, type Message, ConnectionInfo, Packet, User}
import glisten/internal/handler
import inertia_wisp/ssr/internal/netstring

pub type ListenerMessage {
  RegisterWorker(id: Int, worker: Subject(WorkerMessage), reply: Subject(Nil))
  UnregisterWorker(id: Int)
  ConnectionReady(id: Int, sender: Subject(handler.Message(SenderMessage)))
  ConnectionData(id: Int, data: BitArray)
  ConnectionClosed(id: Int)
}

pub type WorkerMessage {
  TcpConnected(send: Subject(handler.Message(SenderMessage)))
  TcpData(data: BitArray)
  TcpClosed
}

pub type ListenerInfo {
  ListenerInfo(subject: Subject(ListenerMessage), port: Int)
}

pub type ListenerError {
  GlistenStartFailed(String)
}

type ListenerState {
  ListenerState(
    workers: Dict(Int, Subject(WorkerMessage)),
    connections: Dict(Int, Subject(handler.Message(SenderMessage))),
  )
}

type ConnState {
  AwaitingId(buffer: BytesTree, listener: Subject(ListenerMessage))
  Identified(worker_id: Int, listener: Subject(ListenerMessage))
}

// Messages for sending data to TCP
pub type SenderMessage {
  WriteToSocket(BitArray)
}

pub fn start() -> Result(ListenerInfo, ListenerError) {
  let listener_name = process.new_name("inertia_ssr_listener")

  let initialise = fn(listener_subject: Subject(ListenerMessage)) {
    use tcp_server <- result.try(
      glisten.new(
        fn(_conn) { init_connection(listener_subject) },
        fn(state, msg, conn) { handle_connection(state, msg, conn) },
      )
      |> glisten.with_close(handle_close)
      |> glisten.bind("127.0.0.1")
      |> glisten.start_with_listener_name(0, listener_name)
      |> result.map_error(fn(err) {
        "glisten start failed: " <> string.inspect(err)
      }),
    )

    let ConnectionInfo(port:, ..) = glisten.get_server_info(listener_name, 5000)
    let _ = process.link(tcp_server.pid)

    let initial_state =
      ListenerState(workers: dict.new(), connections: dict.new())

    let selector =
      process.new_selector()
      |> process.select(listener_subject)

    actor.initialised(initial_state)
    |> actor.selecting(selector)
    |> actor.returning(#(listener_subject, port))
    |> Ok
  }

  case
    actor.new_with_initialiser(10_000, initialise)
    |> actor.on_message(handle_listener_message)
    |> actor.start
  {
    Ok(started) -> {
      let #(subject, port) = started.data
      Ok(ListenerInfo(subject:, port:))
    }
    Error(_) -> Error(GlistenStartFailed("Failed to start listener actor"))
  }
}

fn handle_listener_message(
  state: ListenerState,
  msg: ListenerMessage,
) -> actor.Next(ListenerState, ListenerMessage) {
  case msg {
    RegisterWorker(id, worker, reply) -> {
      let workers = dict.insert(state.workers, id, worker)
      process.send(reply, Nil)
      actor.continue(ListenerState(workers:, connections: state.connections))
    }

    UnregisterWorker(id) -> {
      let workers = dict.delete(state.workers, id)
      let connections = dict.delete(state.connections, id)
      actor.continue(ListenerState(workers:, connections:))
    }

    ConnectionReady(id, sender) -> {
      case dict.get(state.workers, id) {
        Ok(worker) -> {
          process.send(worker, TcpConnected(sender))
          let connections = dict.insert(state.connections, id, sender)
          actor.continue(ListenerState(
            workers: state.workers,
            connections: connections,
          ))
        }
        Error(Nil) -> actor.continue(state)
      }
    }

    ConnectionData(id, data) -> {
      case dict.get(state.workers, id) {
        Ok(worker) -> process.send(worker, TcpData(data))
        Error(Nil) -> Nil
      }
      actor.continue(state)
    }

    ConnectionClosed(id) -> {
      case dict.get(state.workers, id) {
        Ok(worker) -> process.send(worker, TcpClosed)
        Error(Nil) -> Nil
      }
      let connections = dict.delete(state.connections, id)
      actor.continue(ListenerState(workers: state.workers, connections:))
    }
  }
}

fn init_connection(
  listener: Subject(ListenerMessage),
) -> #(ConnState, Option(process.Selector(SenderMessage))) {
  #(AwaitingId(buffer: bytes_tree.new(), listener:), None)
}

fn handle_connection(
  state: ConnState,
  msg: Message(SenderMessage),
  conn: Connection(SenderMessage),
) -> glisten.Next(ConnState, Message(SenderMessage)) {
  case state {
    AwaitingId(buffer, listener) ->
      handle_awaiting_id(buffer, listener, msg, conn)
    Identified(worker_id, listener) ->
      handle_identified(worker_id, listener, msg, conn)
  }
}

fn handle_awaiting_id(
  buffer: BytesTree,
  listener: Subject(ListenerMessage),
  msg: Message(SenderMessage),
  conn: Connection(SenderMessage),
) -> glisten.Next(ConnState, Message(SenderMessage)) {
  case msg {
    User(_) -> glisten.continue(AwaitingId(buffer, listener))
    Packet(data) -> {
      let new_buffer = bytes_tree.append(buffer, data)
      case netstring.decode(bytes_tree.to_bit_array(new_buffer)) {
        Error(netstring.NeedMore) ->
          glisten.continue(AwaitingId(buffer: new_buffer, listener:))
        Error(netstring.InvalidFormat(_)) -> glisten.stop()
        Ok(#(id_str, _remaining)) ->
          case int.parse(id_str) {
            Error(Nil) -> glisten.stop()
            Ok(worker_id) -> {
              process.send(listener, ConnectionReady(worker_id, conn.subject))
              glisten.continue(Identified(worker_id, listener))
            }
          }
      }
    }
  }
}

fn handle_identified(
  worker_id: Int,
  listener: Subject(ListenerMessage),
  msg: Message(SenderMessage),
  conn: Connection(SenderMessage),
) -> glisten.Next(ConnState, Message(SenderMessage)) {
  let state = Identified(worker_id, listener)
  case msg {
    Packet(data) -> {
      process.send(listener, ConnectionData(worker_id, data))
      glisten.continue(state)
    }
    User(WriteToSocket(data)) -> {
      let _ = glisten.send(conn, bytes_tree.from_bit_array(data))
      glisten.continue(state)
    }
  }
}

fn handle_close(state: ConnState) -> Nil {
  case state {
    Identified(worker_id, listener) ->
      process.send(listener, ConnectionClosed(worker_id))
    AwaitingId(..) -> Nil
  }
}
