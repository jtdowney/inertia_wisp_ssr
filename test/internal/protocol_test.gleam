import gleam/json
import gleam/string
import gleeunit/should
import inertia_wisp_ssr/internal/protocol

pub fn encode_request_test() {
  let page_data =
    json.object([
      #("component", json.string("Home")),
      #("props", json.object([])),
    ])

  let encoded = protocol.encode_request(page_data)

  string.starts_with(encoded, "ISSR") |> should.be_true
  string.ends_with(encoded, "\n") |> should.be_true
  string.contains(encoded, "\"page\"") |> should.be_true
}

pub fn decode_response_success_test() {
  let line =
    "ISSR{\"ok\":true,\"head\":[\"<title>Test</title>\"],\"body\":\"<div>Hi</div>\"}\n"

  case protocol.decode_response(line) {
    Ok(protocol.SsrSuccess(head, body)) -> {
      head |> should.equal(["<title>Test</title>"])
      body |> should.equal("<div>Hi</div>")
    }
    _ -> should.fail()
  }
}

pub fn decode_response_error_test() {
  let line = "ISSR{\"ok\":false,\"error\":\"Component not found\"}\n"

  case protocol.decode_response(line) {
    Ok(protocol.SsrRenderError(error)) -> {
      error |> should.equal("Component not found")
    }
    _ -> should.fail()
  }
}

pub fn decode_response_not_protocol_test() {
  let line = "Some random console.log output\n"

  case protocol.decode_response(line) {
    Error(protocol.NotProtocolLine) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn decode_response_invalid_json_test() {
  let line = "ISSR{invalid json}\n"

  case protocol.decode_response(line) {
    Error(protocol.InvalidJson(_)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}
