module.exports.render = async function(page) {
  return {
    head: [`<title>${page.component}</title>`],
    body: `<div id="app">${JSON.stringify(page.props)}</div>`
  };
};
