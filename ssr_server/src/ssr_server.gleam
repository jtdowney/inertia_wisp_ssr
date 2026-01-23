import argv
import envoy
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/javascript/promise
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import inertia_wisp/ssr/internal/netstring
import node_socket_client.{type Event, type SocketClient}
import ssr_server/render.{type RenderModule}

type State {
  State(
    module: RenderModule,
    module_path: String,
    worker_id: Int,
    buffer: BitArray,
    socket: Option(SocketClient),
  )
}

pub fn main() {
  case parse_args() {
    Ok(#(port, module_path, worker_id)) ->
      start_client(port, module_path, worker_id)
    Error(msg) -> {
      io.println_error(
        "Usage: node ssr-server.cjs <port> <module_path> <worker_id>",
      )
      io.println_error("Error: " <> msg)
      exit(1)
    }
  }
}

fn start_client(port: Int, module_path: String, worker_id: Int) -> Nil {
  debug(
    "Starting SSR client, port="
    <> int.to_string(port)
    <> ", module="
    <> module_path
    <> ", worker_id="
    <> int.to_string(worker_id),
  )
  case render.load_module(module_path) {
    Ok(module) -> {
      debug("Render module loaded successfully")
      let state =
        State(
          module: module,
          module_path: module_path,
          worker_id: worker_id,
          buffer: <<>>,
          socket: None,
        )
      let _socket =
        node_socket_client.connect(
          "127.0.0.1",
          port,
          state,
          fn(state, socket, event) { handle_event(state, socket, event) },
        )
      Nil
    }
    Error(err) -> {
      io.println_error(
        "Failed to load render module: " <> render_error_to_string(err),
      )
      exit(1)
    }
  }
}

fn handle_event(
  state: State,
  socket: SocketClient,
  event: Event(String),
) -> State {
  case event {
    node_socket_client.ConnectEvent -> {
      debug("Connected to TCP server")
      let id_frame = netstring.encode(int.to_string(state.worker_id))
      let _ = node_socket_client.write(socket, id_frame)
      State(..state, socket: Some(socket))
    }

    node_socket_client.DataEvent(data) -> {
      debug("Received data, length=" <> int.to_string(string.length(data)))
      let data_bits = bit_array.from_string(data)
      let new_buffer = bit_array.append(state.buffer, data_bits)
      process_buffer(state, socket, new_buffer)
    }

    node_socket_client.CloseEvent(_had_error) -> {
      debug("Connection closed")
      exit(0)
      state
    }

    node_socket_client.ErrorEvent(err) -> {
      debug("Socket error: " <> err)
      io.println_error("Socket error: " <> err)
      exit(1)
      state
    }

    _ -> state
  }
}

fn process_buffer(state: State, socket: SocketClient, buffer: BitArray) -> State {
  case netstring.decode(buffer) {
    Ok(#(json_str, remaining)) -> {
      handle_request(state, socket, json_str)
      process_buffer(state, socket, remaining)
    }
    Error(netstring.NeedMore) -> State(..state, buffer: buffer)
    Error(netstring.InvalidFormat(msg)) -> {
      io.println_error("Invalid frame format: " <> msg)
      exit(1)
      state
    }
  }
}

fn handle_request(state: State, socket: SocketClient, json_str: String) -> Nil {
  debug("Processing render request")
  let module = reload_module_if_needed(state)

  case json.parse(json_str, request_decoder()) {
    Ok(page) -> {
      debug("Request parsed, calling render")
      let _ =
        render.call_render(module, page)
        |> promise.tap(fn(result) {
          case result {
            Ok(_) -> debug("Render succeeded")
            Error(err) ->
              debug("Render failed: " <> render_error_to_string(err))
          }
          send_response(socket, build_response(result))
        })
      Nil
    }
    Error(_) -> {
      debug("Failed to parse request JSON")
      let response =
        json.object([
          #("ok", json.bool(False)),
          #("error", json.string("Invalid request JSON")),
        ])
      send_response(socket, response)
    }
  }
}

fn send_response(socket: SocketClient, response: Json) -> Nil {
  let frame =
    json.to_string(response)
    |> netstring.encode
  debug("Sending response, length=" <> int.to_string(string.length(frame)))
  let _ = node_socket_client.write(socket, frame)

  Nil
}

fn reload_module_if_needed(state: State) -> RenderModule {
  case is_production() {
    True -> state.module
    False -> {
      debug("Reloading module (NODE_ENV != production)")
      render.load_module(state.module_path)
      |> result.unwrap(state.module)
    }
  }
}

fn is_production() -> Bool {
  case envoy.get("NODE_ENV") {
    Ok("production") -> True
    _ -> False
  }
}

fn is_debug() -> Bool {
  case envoy.get("DEBUG_SSR") {
    Ok("1") | Ok("true") -> True
    _ -> False
  }
}

fn debug(msg: String) -> Nil {
  case is_debug() {
    True -> io.println_error("[DEBUG_SSR] " <> msg)
    False -> Nil
  }
}

fn build_response(
  result: Result(render.RenderedPage, render.RenderError),
) -> Json {
  case result {
    Ok(render.RenderedPage(head, body)) ->
      json.object([
        #("ok", json.bool(True)),
        #("head", json.array(head, json.string)),
        #("body", json.string(body)),
      ])
    Error(err) ->
      json.object([
        #("ok", json.bool(False)),
        #("error", json.string(render_error_to_string(err))),
      ])
  }
}

fn request_decoder() -> decode.Decoder(decode.Dynamic) {
  use page <- decode.field("page", decode.dynamic)
  decode.success(page)
}

fn render_error_to_string(err: render.RenderError) -> String {
  case err {
    render.ModuleNotFound(path) -> "Module not found: " <> path
    render.NoRenderExport(path) -> "No render export in: " <> path
    render.RenderFailed(msg) -> msg
  }
}

fn parse_args() -> Result(#(Int, String, Int), String) {
  case argv.load().arguments {
    [port_str, module_path, worker_id_str, ..] -> {
      use port <- result.try(
        int.parse(port_str)
        |> result.map_error(fn(_) { "Invalid port: " <> port_str }),
      )
      use worker_id <- result.try(
        int.parse(worker_id_str)
        |> result.map_error(fn(_) { "Invalid worker_id: " <> worker_id_str }),
      )
      Ok(#(port, module_path, worker_id))
    }
    _ -> Error("Missing required arguments")
  }
}

@external(javascript, "process", "exit")
fn exit(code: Int) -> Nil
