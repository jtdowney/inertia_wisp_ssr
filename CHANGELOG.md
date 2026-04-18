# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-04-18

### Changed

- Upgraded `glisten` to 9.0 and `child_process` to 2.1

### Deprecated

- `ssr.make_layout(config)` in favor of `ssr.layout(config, _)` using
  Gleam's function hole syntax

## [0.1.1] - 2025-01-23

### Added

- `LayoutHandler` type alias for layout function return type

### Documentation

- Document Vite `noExternal` configuration for SSR

## [0.1.0] - 2025-01-23

### Added

- Hybrid Gleam/Node.js server-side rendering for Inertia.js applications
- Worker pool with OTP supervision for managing Node.js render processes
- Automatic client-side rendering (CSR) fallback when SSR fails
- Configurable pool size, render timeout, and render module path

[0.2.0]: https://github.com/jtdowney/inertia_wisp_ssr/releases/tag/v0.2.0
[0.1.1]: https://github.com/jtdowney/inertia_wisp_ssr/releases/tag/v0.1.1
[0.1.0]: https://github.com/jtdowney/inertia_wisp_ssr/releases/tag/v0.1.0
