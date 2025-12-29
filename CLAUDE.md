# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Gleam library providing server-side rendering (SSR) for Inertia.js applications via `inertia_wisp`. Uses a pool of Node.js worker processes managed by the `poolboy` pooling library with automatic CSR fallback on failure.

## Build Commands

```bash
gleam build              # Compile the project
gleam test               # Run all tests
gleam docs build         # Generate documentation
```

## Architecture

**SSR Flow:**

```
inertia.response() with layout(template) from make_layout(config)
    → bath pool checks out a worker
    → worker.call() sends NDJSON request to Node.js process
    → Node.js renders page, returns NDJSON response
    → Success: template receives {head, body}
    → Failure: CSR fallback with <div id="app" data-page="...">
```

**Key Modules:**

- `src/inertia_wisp_ssr.gleam` — Public API: `PoolName`, `SsrConfig`, `default_config()`, `supervised()`, `layout()`, `make_layout()`
- `src/inertia_wisp_ssr/internal/worker.gleam` — OTP actor managing a Node.js child process
- `src/inertia_wisp_ssr/internal/protocol.gleam` — NDJSON protocol encoding/decoding with ISSR prefix
- `priv/ssr-server.cjs` — Node.js server script that loads user's render module

**Architecture:** Gleam OTP actors → `child_process` package → Node.js processes, pooled via `poolboy`

**Startup:** Use `inertia_wisp_ssr.supervised(config)` which returns `ChildSpecification(Nil)` for adding to your supervision tree.

## Dependencies

Pure Gleam implementation - no Elixir runtime required. Uses:
- `child_process` — Spawning and communicating with Node.js processes
- `poolboy` — Resource pooling with blocking checkout

**Important:** Set `NODE_ENV=production` so the SSR script caches the render module in memory. Without this, the module is reloaded on each request (useful for development hot-reload).

## Testing

Tests use `gleeunit` with `should` assertions. Test files in `test/` mirror source structure.

```bash
gleam test                           # Run all tests
gleam test -- --filter worker_test   # Run specific test module
```

## Protocol

Communication with Node.js uses NDJSON (newline-delimited JSON) with an `ISSR` prefix to distinguish protocol messages from console output:

Request: `ISSR{"page": {...}}\n`
Response: `ISSR{"ok": true, "head": [...], "body": "..."}\n` or `ISSR{"ok": false, "error": "..."}\n`
