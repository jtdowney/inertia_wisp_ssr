import gleam/string
import gleam/string_tree
import inertia_wisp/ssr/internal/child.{Complete, Incomplete}

pub fn decode_chunk_incomplete_without_newline_test() {
  let buffer = string_tree.new()
  let chunk = "ISSR{\"ok\":true,\"head\":[],\"body\":\"partial"

  let result = child.decode_chunk(buffer, chunk)
  let assert Incomplete(new_buffer) = result

  assert string_tree.to_string(new_buffer) == chunk
}

pub fn decode_chunk_complete_with_newline_test() {
  let buffer = string_tree.new()
  let chunk = "ISSR{\"ok\":true,\"head\":[\"<title>Test</title>\"],\"body\":\"hello\"}\n"

  let result = child.decode_chunk(buffer, chunk)
  let assert Complete(result: Ok(page), remaining: _) = result

  assert page.body == "hello"
  assert page.head == ["<title>Test</title>"]
}

pub fn decode_chunk_multi_chunk_assembly_test() {
  let buffer = string_tree.new()

  let chunk1 = "ISSR{\"ok\":true,\"head\":"
  let assert Incomplete(buffer1) = child.decode_chunk(buffer, chunk1)

  let chunk2 = "[],\"body\":\"assembled\"}\n"
  let result = child.decode_chunk(buffer1, chunk2)
  let assert Complete(result: Ok(page), remaining: _) = result

  assert page.body == "assembled"
  assert page.head == []
}

pub fn decode_chunk_skips_console_output_test() {
  let buffer = string_tree.new()
  let chunk =
    "console.log output\n[LOG] Some debug info\nISSR{\"ok\":true,\"head\":[],\"body\":\"real\"}\n"

  let result = child.decode_chunk(buffer, chunk)
  let assert Complete(result: Ok(page), remaining: _) = result

  assert page.body == "real"
}

pub fn decode_chunk_error_response_test() {
  let buffer = string_tree.new()
  let chunk = "ISSR{\"ok\":false,\"error\":\"Component not found\"}\n"

  let result = child.decode_chunk(buffer, chunk)
  let assert Complete(result: Error(msg), remaining: _) = result

  assert string.contains(msg, "render error")
  assert string.contains(msg, "Component not found")
}

pub fn decode_chunk_invalid_json_test() {
  let buffer = string_tree.new()
  let chunk = "ISSR{invalid json}\n"

  let result = child.decode_chunk(buffer, chunk)
  let assert Complete(result: Error(msg), remaining: _) = result

  assert string.contains(msg, "invalid response")
}

pub fn decode_chunk_preserves_remaining_test() {
  let buffer = string_tree.new()
  let chunk = "ISSR{\"ok\":true,\"head\":[],\"body\":\"x\"}\nextra data here"

  let result = child.decode_chunk(buffer, chunk)
  let assert Complete(result: Ok(_), remaining: rest) = result

  assert string_tree.to_string(rest) == "extra data here"
}
