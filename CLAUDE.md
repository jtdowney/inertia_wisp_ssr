# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Gleam library providing server-side rendering (SSR) for Inertia.js applications via `inertia_wisp`. Uses a pool of Node.js worker processes managed by a pure Gleam pool implementation with automatic CSR fallback on failure.

## Build Commands

```bash
just build               # Build main library and ssr_server
just test                # Run all tests
gleam docs build         # Generate documentation
```

## Architecture

**SSR Flow:**

```
inertia.response() with layout(template) from make_layout(config)
    → pool manager checks out a worker (OTP actor)
    → worker spawns Node.js running priv/ssr_server.cjs
    → Node.js connects to TCP server
    → worker sends netstring-framed request over TCP
    → Node.js renders page, returns netstring-framed response
    → Success: template receives {head, body}
    → Failure: CSR fallback with <div id="app" data-page="...">
```

**Key Modules:**

- `src/inertia_wisp/ssr.gleam` — Public API: `SsrConfig`, `default_config()`, `supervised()`, `layout()`, `make_layout()`
- `src/inertia_wisp/ssr/internal/pool.gleam` — Pure Gleam pool manager and pool actor using OTP
- `src/inertia_wisp/ssr/internal/listener.gleam` — TCP server (glisten) that accepts Node.js connections and routes data to workers
- `src/inertia_wisp/ssr/internal/worker.gleam` — Worker actor that spawns and manages a Node.js process
- `src/inertia_wisp/ssr/internal/protocol.gleam` — Netstring + JSON protocol encoding/decoding
- `src/inertia_wisp/ssr/internal/netstring.gleam` — Netstring framing (shared with JS target)
- `ssr_server/` — Gleam subproject compiled to JavaScript (the Node.js TCP client)
- `priv/ssr_server.cjs` — Bundled JavaScript that Node.js runs (built from ssr_server/)

**Architecture:** Pool starts listener (glisten TCP server) → pool spawns workers → workers spawn Node.js via `child_process` → Node.js connects back to listener → listener routes TCP data to workers

**Startup:** Use `ssr.supervised(config)` (from `inertia_wisp/ssr`) which returns `ChildSpecification(Nil)` for adding to your supervision tree.

## Dependencies

Pure Gleam implementation - no Elixir runtime or Erlang FFI required. Uses:

- `glisten` — TCP server for Node.js connections
- `gleam_otp` — Actor-based pool and worker management
- `gleam_json` — JSON encoding/decoding
- `gleam_time` — Duration type for timeouts
- `child_process` — Spawning and managing Node.js processes

**Important:** Set `NODE_ENV=production` so the SSR script caches the render module in memory. Without this, the module is reloaded on each request (useful for development hot-reload).

## Testing

Tests use `unitest` with assert expressions. Test files in `test/` mirror source structure.

```bash
just test                            # Run all tests
```

## Protocol

Communication with Node.js uses netstring-framed JSON over TCP:

```
Netstring format: <length>:<data>,
```

Request: `{"page": {...}}`
Response: `{"ok": true, "head": [...], "body": "..."}` or `{"ok": false, "error": "..."}`
