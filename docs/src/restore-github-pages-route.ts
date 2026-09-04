(function restoreGitHubPagesRoute(location: Location) {
  if (location.search.slice(0, 2) !== "?/") return;
  const decoded = location.search
    .slice(1)
    .split("&")
    .map(value => value.replace(/~and~/g, "&"))
    .join("?");
  window.history.replaceState(null, "", location.pathname.slice(0, -1) + decoded + location.hash);
})(window.location);
