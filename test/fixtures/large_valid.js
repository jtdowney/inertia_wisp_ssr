// Returns a large but valid payload for boundary testing
// Body is ~900KB, well under the 1MB buffer limit

function render(page) {
  return {
    head: ["<title>Large</title>"],
    body: "<div>" + "x".repeat(900000) + "</div>"
  };
}

module.exports = { render };
