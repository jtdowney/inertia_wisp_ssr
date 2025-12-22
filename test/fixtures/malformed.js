// Returns malformed SSR result for testing decode error messages

function render(page) {
  // Return object with wrong types to trigger decode errors
  // head should be a list of strings, body should be a string
  return {
    head: "not-a-list",  // Wrong: should be array
    body: 123            // Wrong: should be string
  };
}

module.exports = { render };
