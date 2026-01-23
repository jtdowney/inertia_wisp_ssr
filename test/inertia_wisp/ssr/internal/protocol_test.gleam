import birdie
import gleam/bit_array
import gleam/bytes_tree
import gleam/json
import inertia_wisp/ssr/internal/netstring
import inertia_wisp/ssr/internal/protocol

pub fn encode_request_netstring_test() {
  let page_data =
    json.object([
      #("name", json.string("John")),
      #("content", json.string("Test")),
    ])

  let result =
    protocol.encode_request(page_data)
    |> bytes_tree.to_bit_array
    |> bit_array.to_string

  let assert Ok(str) = result
  str
  |> birdie.snap("encode request netstring format")
}

pub fn decode_response_complete_test() {
  let json_str =
    json.object([
      #("ok", json.bool(True)),
      #("head", json.array([], json.string)),
      #("body", json.string("test")),
    ])
    |> json.to_string
  let frame = bit_array.from_string("35:" <> json_str <> ",")

  let assert Ok(#(Ok(page), remaining)) = protocol.decode_response(frame)
  assert page.head == []
  assert page.body == "test"
  assert remaining == <<>>
}

pub fn decode_response_incomplete_header_test() {
  let frame = bit_array.from_string("35")
  assert protocol.decode_response(frame)
    == Error(protocol.NetstringError(netstring.NeedMore))
}

pub fn decode_response_incomplete_body_test() {
  let frame = bit_array.from_string("35:{\"ok\":")
  assert protocol.decode_response(frame)
    == Error(protocol.NetstringError(netstring.NeedMore))
}

pub fn decode_response_missing_comma_test() {
  let json_str =
    json.object([#("ok", json.bool(True))])
    |> json.to_string
  let frame = bit_array.from_string("11:" <> json_str)
  assert protocol.decode_response(frame)
    == Error(protocol.NetstringError(netstring.NeedMore))
}

pub fn decode_frame_invalid_length_test() {
  let frame = bit_array.from_string("abc:{},")
  let assert Error(protocol.NetstringError(netstring.InvalidFormat(_))) =
    protocol.decode_response(frame)
}

pub fn decode_response_success_test() {
  let json_str =
    json.object([
      #("ok", json.bool(True)),
      #("head", json.array(["<title>Test</title>"], json.string)),
      #("body", json.string("<div>Hello</div>")),
    ])
    |> json.to_string
  let frame = netstring.encode(json_str) |> bit_array.from_string
  let assert Ok(#(Ok(page), _remaining)) = protocol.decode_response(frame)
  assert page.head == ["<title>Test</title>"]
  assert page.body == "<div>Hello</div>"
}

pub fn decode_response_error_test() {
  let json_str =
    json.object([
      #("ok", json.bool(False)),
      #("error", json.string("Component not found")),
    ])
    |> json.to_string
  let frame = netstring.encode(json_str) |> bit_array.from_string
  let assert Ok(#(Error(protocol.RenderError(msg)), _remaining)) =
    protocol.decode_response(frame)
  assert msg == "Component not found"
}

pub fn decode_response_invalid_json_test() {
  let frame = bit_array.from_string("13:{invalid json,")
  let assert Error(protocol.InvalidJson(_)) = protocol.decode_response(frame)
}

pub fn decode_response_empty_head_test() {
  let json_str =
    json.object([
      #("ok", json.bool(True)),
      #("head", json.array([], json.string)),
      #("body", json.string("body")),
    ])
    |> json.to_string
  let frame = netstring.encode(json_str) |> bit_array.from_string
  let assert Ok(#(Ok(page), _remaining)) = protocol.decode_response(frame)
  assert page.head == []
  assert page.body == "body"
}

pub fn decode_response_with_remaining_test() {
  let json1 =
    json.object([
      #("ok", json.bool(True)),
      #("head", json.array([], json.string)),
      #("body", json.string("first")),
    ])
    |> json.to_string
  let json2 =
    json.object([
      #("ok", json.bool(True)),
      #("head", json.array([], json.string)),
      #("body", json.string("second")),
    ])
    |> json.to_string
  let frame =
    bit_array.from_string(netstring.encode(json1) <> netstring.encode(json2))

  let assert Ok(#(Ok(first), remaining)) = protocol.decode_response(frame)
  assert first.body == "first"

  let assert Ok(#(Ok(second), final)) = protocol.decode_response(remaining)
  assert second.body == "second"
  assert final == <<>>
}
