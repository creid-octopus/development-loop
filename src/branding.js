// Tenant branding. Octopus sets BRAND_NAME and BRAND_COLOR on tenanted deploys.
// Untenanted deploys leave them empty and get the defaults: the standard title
// and the environment's banner colour.

const DEFAULT_NAME = "developmentloop demo";
const HEX_COLOUR = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// Returns the name to show (HTML-escaped) and the banner colour. A colour that
// isn't a hex value is ignored, so a bad tenant value can't break the page's CSS.
function branding(env, fallbackColour) {
  const name = (env.BRAND_NAME || "").trim();
  const colour = (env.BRAND_COLOR || "").trim();
  return {
    name: escapeHtml(name || DEFAULT_NAME),
    colour: HEX_COLOUR.test(colour) ? colour : fallbackColour,
    tenanted: name !== "",
  };
}

module.exports = { branding, DEFAULT_NAME };
