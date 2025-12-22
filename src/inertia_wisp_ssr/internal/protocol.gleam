import gleam/dynamic/decode
import gleam/json
import gleam/string

const prefix = "ISSR"

/// SSR render result from Node.js
pub type SsrResult {
  SsrSuccess(head: List(String), body: String)
  SsrRenderError(error: String)
}

/// Decode error types
pub type DecodeError {
  NotProtocolLine
  InvalidJson(String)
}

/// Encode a page data request as an ISSR-prefixed NDJSON line.
pub fn encode_request(page_data: json.Json) -> String {
  let request = json.object([#("page", page_data)])
  prefix <> json.to_string(request) <> "\n"
}

/// Decode a response line from Node.js.
/// Returns Error(NotProtocolLine) for non-ISSR lines (should be ignored).
/// Returns Error(InvalidJson) for malformed ISSR lines.
pub fn decode_response(line: String) -> Result(SsrResult, DecodeError) {
  let trimmed = string.trim_end(line)

  case string.starts_with(trimmed, prefix) {
    False -> Error(NotProtocolLine)
    True -> {
      let json_str = string.drop_start(trimmed, string.length(prefix))
      case json.parse(json_str, response_decoder()) {
        Ok(result) -> Ok(result)
        Error(err) -> Error(InvalidJson(json_error_to_string(err)))
      }
    }
  }
}

fn response_decoder() -> decode.Decoder(SsrResult) {
  use ok <- decode.field("ok", decode.bool)
  case ok {
    True -> {
      use head <- decode.field("head", decode.list(decode.string))
      use body <- decode.field("body", decode.string)
      decode.success(SsrSuccess(head: head, body: body))
    }
    False -> {
      use error <- decode.field("error", decode.string)
      decode.success(SsrRenderError(error: error))
    }
  }
}

fn json_error_to_string(err: json.DecodeError) -> String {
  case err {
    json.UnexpectedByte(s) -> "unexpected byte: " <> s
    json.UnexpectedEndOfInput -> "unexpected end of input"
    json.UnexpectedSequence(s) -> "unexpected sequence: " <> s
    json.UnableToDecode(_) -> "unable to decode"
  }
}
