import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/string

const prefix = "ISSR"

pub type Page {
  Page(head: List(String), body: String)
}

pub type DecodeError {
  NotProtocolLine
  RenderError(String)
  InvalidJson(String)
}

pub fn encode_request(page_data: Json) -> String {
  let request = json.object([#("page", page_data)])
  prefix <> json.to_string(request) <> "\n"
}

pub fn decode_response(line: String) -> Result(Page, DecodeError) {
  let trimmed = string.trim_end(line)

  case string.starts_with(trimmed, prefix) {
    False -> Error(NotProtocolLine)
    True -> {
      let json_str = string.drop_start(trimmed, string.length(prefix))
      case json.parse(json_str, response_decoder()) {
        Ok(Ok(result)) -> Ok(result)
        Ok(Error(error)) -> Error(RenderError(error))
        Error(err) -> Error(InvalidJson(json_error_to_string(err)))
      }
    }
  }
}

fn response_decoder() -> decode.Decoder(Result(Page, String)) {
  use ok <- decode.field("ok", decode.bool)
  case ok {
    True -> {
      use head <- decode.field("head", decode.list(decode.string))
      use body <- decode.field("body", decode.string)
      decode.success(Ok(Page(head: head, body: body)))
    }
    False -> {
      use error <- decode.field("error", decode.string)
      decode.success(Error(error))
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
