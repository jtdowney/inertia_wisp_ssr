import gleam/bytes_tree.{type BytesTree}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/result
import inertia_wisp/ssr/internal/netstring

pub type Page {
  Page(head: List(String), body: String)
}

pub type ProtocolError {
  NetstringError(netstring.NetstringError)
  InvalidJson(String)
  RenderError(String)
}

pub fn encode_request(page_data: Json) -> BytesTree {
  let request = json.object([#("page", page_data)])
  encode_frame(request)
}

fn encode_frame(data: Json) -> BytesTree {
  json.to_string_tree(data)
  |> netstring.encode_tree
  |> bytes_tree.from_string_tree
}

pub fn decode_response(
  buffer: BitArray,
) -> Result(#(Result(Page, ProtocolError), BitArray), ProtocolError) {
  use decoded_frame <- result.try(
    netstring.decode(buffer)
    |> result.map_error(NetstringError),
  )

  let #(frame, rest) = decoded_frame
  use decoded_result <- result.try(
    json.parse(frame, response_decoder())
    |> result.map_error(fn(err) { InvalidJson(json_error_to_string(err)) }),
  )

  case decoded_result {
    Ok(page) -> Ok(#(Ok(page), rest))
    Error(error) -> Ok(#(Error(RenderError(error)), rest))
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
