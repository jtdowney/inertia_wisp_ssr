async function render(page) {
  await new Promise(resolve => setTimeout(resolve, 50));
  return { head: [], body: "<div>saturated</div>" };
}

module.exports = { render };
