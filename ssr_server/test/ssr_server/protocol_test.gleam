import birdie
import gleam/bit_array
import gleam/json
import inertia_wisp/ssr/internal/netstring

pub fn encode_frame_simple_test() {
  let data = json.object([#("ok", json.bool(True))])
  let frame =
    json.to_string(data)
    |> netstring.encode

  frame
  |> birdie.snap("encode frame simple netstring")
}

pub fn encode_frame_complex_test() {
  let data =
    json.object([
      #("ok", json.bool(True)),
      #("head", json.array(["<title>Test</title>"], json.string)),
      #("body", json.string("<div>Hello</div>")),
    ])
  let frame =
    json.to_string(data)
    |> netstring.encode

  frame
  |> birdie.snap("encode frame complex netstring")
}

pub fn decode_frame_complete_test() {
  let json_str =
    json.object([#("ok", json.bool(True))])
    |> json.to_string
  let buffer = bit_array.from_string("11:" <> json_str <> ",")

  let assert Ok(#(decoded, remaining)) = netstring.decode(buffer)
  assert decoded == json_str
  assert remaining == <<>>
}

pub fn decode_frame_incomplete_header_test() {
  let buffer = bit_array.from_string("11")
  assert netstring.decode(buffer) == Error(netstring.NeedMore)
}

pub fn decode_frame_incomplete_body_test() {
  let buffer = bit_array.from_string("100:hello")
  assert netstring.decode(buffer) == Error(netstring.NeedMore)
}

pub fn decode_frame_missing_comma_test() {
  let buffer = bit_array.from_string("11:{\"ok\":true}")
  assert netstring.decode(buffer) == Error(netstring.NeedMore)
}

pub fn decode_frame_invalid_length_test() {
  let buffer = bit_array.from_string("abc:{\"ok\":true},")
  let assert Error(netstring.InvalidFormat(_)) = netstring.decode(buffer)
}

pub fn decode_frame_with_remaining_data_test() {
  let json1 =
    json.object([#("a", json.int(1))])
    |> json.to_string
  let json2 =
    json.object([#("b", json.int(2))])
    |> json.to_string
  let buffer = bit_array.from_string("7:" <> json1 <> ",7:" <> json2 <> ",")

  let assert Ok(#(decoded, remaining)) = netstring.decode(buffer)
  assert decoded == json1
  assert remaining == bit_array.from_string("7:" <> json2 <> ",")
}

pub fn decode_frame_multiple_frames_test() {
  let json1 =
    json.object([#("first", json.int(1))])
    |> json.to_string
  let json2 =
    json.object([#("second", json.int(2))])
    |> json.to_string
  let buffer = bit_array.from_string("11:" <> json1 <> ",12:" <> json2 <> ",")

  let assert Ok(#(first, remaining1)) = netstring.decode(buffer)
  assert first == json1

  let assert Ok(#(second, remaining2)) = netstring.decode(remaining1)
  assert second == json2
  assert remaining2 == <<>>
}
