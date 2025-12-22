// Minimal SSR bundle for integration tests
// Returns a simple head and body based on the page object

function render(page) {
  const component = page.component || "Unknown";
  const props = page.props || {};

  return {
    head: [
      `<title>${component}</title>`,
      `<meta name="test" content="true">`
    ],
    body: `<div id="app" data-component="${component}">${JSON.stringify(props)}</div>`
  };
}

module.exports = { render };
