//// Shared between Erlang and JavaScript targets.
//// Uses bit_array for byte-aware operations to handle UTF-8 correctly.

import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

pub type NetstringError {
  NeedMore
  InvalidFormat(String)
}

pub fn encode(data: String) -> String {
  let length = string.byte_size(data)
  int.to_string(length) <> ":" <> data <> ","
}

pub fn encode_tree(data: StringTree) -> StringTree {
  let length = string_tree.byte_size(data)
  int.to_string(length)
  |> string_tree.from_string
  |> string_tree.append(":")
  |> string_tree.append_tree(data)
  |> string_tree.append(",")
}

pub fn decode(buffer: BitArray) -> Result(#(String, BitArray), NetstringError) {
  decode_bytes_inner(buffer, 0, 0)
}

fn decode_bytes_inner(
  buffer: BitArray,
  index: Int,
  acc: Int,
) -> Result(#(String, BitArray), NetstringError) {
  case bit_array.slice(buffer, index, 1) {
    Ok(<<58>>) -> extract_data_bits(buffer, index + 1, acc)
    Ok(<<digit>>) if digit >= 48 && digit <= 57 ->
      decode_bytes_inner(buffer, index + 1, acc * 10 + digit - 48)
    Ok(_) -> Error(InvalidFormat("Invalid character in length"))
    Error(Nil) -> Error(NeedMore)
  }
}

fn extract_data_bits(
  buffer: BitArray,
  data_start: Int,
  length: Int,
) -> Result(#(String, BitArray), NetstringError) {
  let buffer_size = bit_array.byte_size(buffer)
  use <- bool.guard(buffer_size < data_start + length + 1, Error(NeedMore))

  use data_bytes <- result.try(
    bit_array.slice(buffer, data_start, length)
    |> result.replace_error(NeedMore),
  )

  use <- bool.guard(
    bit_array.slice(buffer, data_start + length, 1) != Ok(<<44>>),
    Error(InvalidFormat("Missing trailing comma")),
  )

  use data <- result.try(
    bit_array.to_string(data_bytes)
    |> result.replace_error(InvalidFormat("Invalid UTF-8 in data")),
  )

  let remaining_start = data_start + length + 1
  let remaining_len = buffer_size - remaining_start

  case bit_array.slice(buffer, remaining_start, remaining_len) {
    Ok(remaining_bytes) -> Ok(#(data, remaining_bytes))
    Error(Nil) -> Ok(#(data, <<>>))
  }
}
