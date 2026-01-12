function render(page) {
  console.log("Debug:", page.component);
  console.warn("Warning message");
  return { head: ["<title>Noisy</title>"], body: "<div>noisy</div>" };
}
module.exports = { render };
