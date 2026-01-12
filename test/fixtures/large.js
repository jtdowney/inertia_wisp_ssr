async function render(page) {
  // Generate a body larger than a small buffer limit
  const largeBody = "x".repeat(10000);
  return { head: [], body: largeBody };
}

module.exports = { render };
