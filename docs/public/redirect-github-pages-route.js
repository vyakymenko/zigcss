(function redirectGitHubPagesRoute(location) {
  var pathSegmentsToKeep = 1;
  var repositoryRoot = location.pathname
    .split("/")
    .slice(0, 1 + pathSegmentsToKeep)
    .join("/");
  var route = location.pathname
    .slice(1)
    .split("/")
    .slice(pathSegmentsToKeep)
    .join("/")
    .replace(/&/g, "~and~");
  location.replace(
    location.protocol + "//" + location.hostname + (location.port ? ":" + location.port : "") +
    repositoryRoot + "/?/" + route +
    (location.search ? "&" + location.search.slice(1).replace(/&/g, "~and~") : "") +
    location.hash
  );
})(window.location);
