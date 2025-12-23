async function render(page) {
  await new Promise(resolve => setTimeout(resolve, 500));
  return { head: [], body: "<div>slow</div>" };
}

module.exports = { render };
