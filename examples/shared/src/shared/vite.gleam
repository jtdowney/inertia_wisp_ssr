//// Vite manifest utilities for resolving hashed asset paths.
////
//// This module reads Vite's `manifest.json` to resolve source paths
//// to their built output paths (which may include content hashes).
////
//// ## Example
////
//// ```gleam
//// import shared/vite
////
//// pub fn main() {
////   let assert Ok(priv) = wisp.priv_directory("my_app")
////   let assert Ok(manifest) = vite.load_manifest(priv <> "/static")
////
////   // Returns "/static/main-abc123.js" (or "/static/main.js" if no hash)
////   let assert Ok(path) = vite.asset(manifest, "src/main.jsx", "/static")
//// }
//// ```

import gleam/dict.{type Dict}
import gleam/dynamic/decode.{type Decoder}
import gleam/json
import gleam/result
import simplifile

/// A parsed Vite manifest containing source-to-output mappings.
pub opaque type Manifest {
  Manifest(entries: Dict(String, ManifestEntry))
}

/// A single entry in the Vite manifest.
pub type ManifestEntry {
  ManifestEntry(
    /// The output file path relative to the build directory
    file: String,
    /// The original source file path
    src: String,
    /// Whether this is an entry point
    is_entry: Bool,
  )
}

/// Error types for manifest operations.
pub type ManifestError {
  /// Failed to read the manifest file
  FileError(simplifile.FileError)
  /// Failed to parse the manifest JSON
  ParseError(String)
  /// The requested asset was not found in the manifest
  AssetNotFound(String)
}

/// Load and parse a Vite manifest from the given static directory.
///
/// Looks for `.vite/manifest.json` in the specified directory.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(manifest) = vite.load_manifest(priv <> "/static")
/// ```
pub fn load_manifest(static_dir: String) -> Result(Manifest, ManifestError) {
  let manifest_path = static_dir <> "/.vite/manifest.json"

  use content <- result.try(
    simplifile.read(manifest_path)
    |> result.map_error(FileError),
  )

  use entries <- result.try(
    json.parse(content, manifest_decoder())
    |> result.map_error(fn(err) { ParseError(json_error_to_string(err)) }),
  )

  Ok(Manifest(entries: entries))
}

/// Look up the output path for a source asset.
///
/// Returns the full URL path including the base path prefix.
///
/// ## Parameters
///
/// - `manifest`: The loaded Vite manifest
/// - `src`: The source file path (e.g., "src/main.jsx")
/// - `base_path`: The URL base path for static assets (e.g., "/static")
///
/// ## Example
///
/// ```gleam
/// // If manifest has "src/main.jsx" -> "main-abc123.js"
/// vite.asset(manifest, "src/main.jsx", "/static")
/// // Returns Ok("/static/main-abc123.js")
/// ```
pub fn asset(
  manifest: Manifest,
  src: String,
  base_path: String,
) -> Result(String, ManifestError) {
  case dict.get(manifest.entries, src) {
    Ok(entry) -> Ok(base_path <> "/" <> entry.file)
    Error(_) -> Error(AssetNotFound(src))
  }
}

/// Convenience function to load manifest and resolve an asset in one call.
///
/// Combines `load_manifest` and `asset` for simpler usage when you only
/// need to resolve a single asset path.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(main_js) = vite.resolve(
///   static_dir,
///   "src/main.jsx",
///   "/static",
/// )
/// // Returns "/static/main-abc123.js"
/// ```
pub fn resolve(
  static_dir: String,
  src: String,
  base_path: String,
) -> Result(String, ManifestError) {
  use manifest <- result.try(load_manifest(static_dir))
  asset(manifest, src, base_path)
}

/// Get the raw manifest entry for a source file.
///
/// Useful when you need access to additional metadata like `is_entry`.
pub fn get_entry(
  manifest: Manifest,
  src: String,
) -> Result(ManifestEntry, ManifestError) {
  dict.get(manifest.entries, src)
  |> result.map_error(fn(_) { AssetNotFound(src) })
}

fn manifest_decoder() -> Decoder(Dict(String, ManifestEntry)) {
  decode.dict(decode.string, entry_decoder())
}

fn entry_decoder() -> Decoder(ManifestEntry) {
  use file <- decode.field("file", decode.string)
  use src <- decode.optional_field("src", "", decode.string)
  use is_entry <- decode.optional_field("isEntry", False, decode.bool)
  decode.success(ManifestEntry(file: file, src: src, is_entry: is_entry))
}

fn json_error_to_string(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "Unexpected end of input"
    json.UnexpectedByte(byte) -> "Unexpected byte: " <> byte
    json.UnexpectedSequence(seq) -> "Unexpected sequence: " <> seq
    json.UnableToDecode(_errors) -> "Unable to decode manifest structure"
  }
}
