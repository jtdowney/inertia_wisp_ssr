const path = require('path');

const PREFIX = 'ISSR';
const isProduction = process.env.NODE_ENV === 'production';
const debugSsr = process.env.DEBUG_SSR === '1';
const modulePath = process.argv[2];
const resolvedModulePath = modulePath ? path.resolve(process.cwd(), modulePath) : null;

if (!modulePath) {
  console.error('Usage: node ssr-server.cjs <module-path>');
  process.exit(1);
}

const originalConsole = {
  log: console.log,
  warn: console.warn,
  error: console.error,
};
console.log = (...args) => originalConsole.error('[LOG]', ...args);
console.warn = (...args) => originalConsole.error('[WARN]', ...args);

let cachedRender = null;

async function getRender() {
  if (isProduction && cachedRender) {
    return cachedRender;
  }

  if (!isProduction) {
    try {
      const resolved = require.resolve(resolvedModulePath);
      delete require.cache[resolved];
    } catch (e) {}
  }

  const mod = require(resolvedModulePath);
  const render = mod.render || mod.default?.render || mod.default;

  if (typeof render !== 'function') {
    throw new Error(`Module ${modulePath} does not export a render function`);
  }

  cachedRender = render;
  return render;
}

function writeResponse(response) {
  const json = JSON.stringify(response);
  process.stdout.write(PREFIX + json + '\n');
}

async function handleRequest(line) {
  if (!line.startsWith(PREFIX)) {
    return;
  }

  const jsonStr = line.slice(PREFIX.length);

  try {
    const { page } = JSON.parse(jsonStr);
    if (page == null || typeof page !== 'object') {
      throw new Error('Request must include a "page" object');
    }
    const render = await getRender();
    const result = await render(page);

    const head = result.head || [];
    const body = result.body || '';

    if (!Array.isArray(head)) {
      throw new Error('render() must return { head: string[], body: string } - head is not an array');
    }
    if (typeof body !== 'string') {
      throw new Error('render() must return { head: string[], body: string } - body is not a string');
    }

    writeResponse({
      ok: true,
      head,
      body
    });
  } catch (err) {
    if (debugSsr) {
      originalConsole.error('[SSR Error]', err.stack || err);
    }
    writeResponse({
      ok: false,
      error: err.message || String(err)
    });
  }
}

async function main() {
  if (isProduction) {
    try {
      await getRender();
    } catch (err) {
      originalConsole.error('Failed to pre-load SSR module:', err.message);
      process.exit(1);
    }
  }

  const readline = require('readline');
  const rl = readline.createInterface({
    input: process.stdin,
    terminal: false
  });

  let pending = Promise.resolve();
  rl.on('line', (line) => {
    pending = pending.then(() => handleRequest(line));
  });

  rl.on('close', () => {
    process.exit(0);
  });
}

main();
