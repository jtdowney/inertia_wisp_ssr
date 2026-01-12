import birdie
import gleam/json
import inertia_wisp/ssr/internal/protocol

pub fn encode_request_test() {
  let page_data =
    json.object([
      #("name", json.string("John")),
      #("content", json.string("This is a test page.")),
    ])

  protocol.encode_request(page_data)
  |> birdie.snap("encode request")
}

pub fn decode_valid_success_test() {
  let line =
    "ISSR{\"ok\":true,\"head\":[\"<title>Test</title>\"],\"body\":\"<div>Hello</div>\"}"
  let assert Ok(page) = protocol.decode_response(line)
  assert page.head == ["<title>Test</title>"]
  assert page.body == "<div>Hello</div>"
}

pub fn decode_valid_error_test() {
  let line = "ISSR{\"ok\":false,\"error\":\"Component not found\"}"
  assert protocol.decode_response(line)
    == Error(protocol.RenderError("Component not found"))
}

pub fn decode_non_protocol_line_test() {
  let line = "console.log output from node"
  assert protocol.decode_response(line) == Error(protocol.NotProtocolLine)
}

pub fn decode_invalid_json_test() {
  let line = "ISSR{invalid json"
  let assert Error(protocol.InvalidJson(_)) = protocol.decode_response(line)
}

pub fn decode_empty_head_array_test() {
  let line = "ISSR{\"ok\":true,\"head\":[],\"body\":\"body\"}"
  let assert Ok(page) = protocol.decode_response(line)
  assert page.head == []
  assert page.body == "body"
}

pub fn decode_missing_ok_field_test() {
  let line = "ISSR{\"head\":[],\"body\":\"x\"}"
  let assert Error(protocol.InvalidJson(_)) = protocol.decode_response(line)
}

pub fn decode_head_wrong_type_test() {
  let line = "ISSR{\"ok\":true,\"head\":\"not-array\",\"body\":\"x\"}"
  let assert Error(protocol.InvalidJson(_)) = protocol.decode_response(line)
}

pub fn decode_body_wrong_type_test() {
  let line = "ISSR{\"ok\":true,\"head\":[],\"body\":123}"
  let assert Error(protocol.InvalidJson(_)) = protocol.decode_response(line)
}

pub fn decode_empty_string_test() {
  assert protocol.decode_response("") == Error(protocol.NotProtocolLine)
}

pub fn decode_only_prefix_test() {
  let assert Error(protocol.InvalidJson(_)) = protocol.decode_response("ISSR")
}
