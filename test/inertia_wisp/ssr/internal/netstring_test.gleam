import gleam/bit_array
import inertia_wisp/ssr/internal/netstring

pub fn decode_returns_bitarray_test() {
  let buffer = bit_array.from_string("5:hello,")
  let assert Ok(#(data, remaining)) = netstring.decode(buffer)
  assert data == "hello"
  assert remaining == <<>>
}

pub fn decode_multiple_frames_test() {
  let buffer = bit_array.from_string("5:hello,5:world,")
  let assert Ok(#(first, remaining)) = netstring.decode(buffer)
  assert first == "hello"

  let assert Ok(#(second, final)) = netstring.decode(remaining)
  assert second == "world"
  assert final == <<>>
}

pub fn decode_incomplete_test() {
  let buffer = bit_array.from_string("5:hel")
  assert netstring.decode(buffer) == Error(netstring.NeedMore)
}

pub fn decode_utf8_test() {
  let buffer = bit_array.from_string("6:你好,")
  let assert Ok(#(data, _)) = netstring.decode(buffer)
  assert data == "你好"
}

pub fn decode_empty_data_test() {
  let buffer = bit_array.from_string("0:,")
  let assert Ok(#(data, remaining)) = netstring.decode(buffer)
  assert data == ""
  assert remaining == <<>>
}

pub fn decode_invalid_format_no_colon_test() {
  let buffer = bit_array.from_string("5hello,")
  let assert Error(netstring.InvalidFormat(_)) = netstring.decode(buffer)
}

pub fn decode_invalid_format_no_comma_test() {
  let buffer = bit_array.from_string("5:hello")
  assert netstring.decode(buffer) == Error(netstring.NeedMore)
}
