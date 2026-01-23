import * as path from "path";

import { Result$Ok, Result$Error, toList } from "./gleam.mjs";
import {
  RenderError$ModuleNotFound,
  RenderError$NoRenderExport,
  RenderError$RenderFailed,
  RenderedPage$RenderedPage,
} from "./ssr_server/render.mjs";

function clearModule(moduleId, visited) {
  if (!moduleId || visited.has(moduleId)) {
    return;
  }

  const mod = require.cache[moduleId];
  if (!mod) {
    return;
  }

  visited.add(moduleId);
  for (const child of mod.children) {
    clearModule(child.id, visited);
  }

  delete require.cache[moduleId];
}

function clearRequireCache(resolvedPath) {
  const visited = new Set();

  try {
    const moduleId = require.resolve(resolvedPath);
    clearModule(moduleId, visited);
  } catch {
    // Module not in cache - nothing to clear
  }
}

export function loadModule(modulePath) {
  try {
    const resolvedPath = path.resolve(process.cwd(), modulePath);
    clearRequireCache(resolvedPath);

    const mod = require(resolvedPath);
    const render = mod.render || mod.default?.render || mod.default;

    if (typeof render !== "function") {
      return Result$Error(RenderError$NoRenderExport(modulePath));
    }

    return Result$Ok({ render, path: resolvedPath });
  } catch (e) {
    if (e.code === "MODULE_NOT_FOUND") {
      return Result$Error(RenderError$ModuleNotFound(modulePath));
    }

    return Result$Error(RenderError$RenderFailed(e.message || String(e)));
  }
}

export async function callRender(module, page) {
  try {
    const result = await module.render(page);
    const head = result.head ?? [];
    const body = result.body ?? "";

    if (!Array.isArray(head)) {
      return Result$Error(RenderError$RenderFailed("head must be an array"));
    }

    if (typeof body !== "string") {
      return Result$Error(RenderError$RenderFailed("body must be a string"));
    }

    return Result$Ok(RenderedPage$RenderedPage(toList(head), body));
  } catch (e) {
    return Result$Error(RenderError$RenderFailed(e.message || String(e)));
  }
}
