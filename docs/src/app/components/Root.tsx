import { Outlet, Link, useLocation } from "react-router";
import { Github, Code2 } from "lucide-react";

export function Root() {
  const location = useLocation();

  const isActive = (path: string) => {
    if (path === "/") {
      return location.pathname === "/";
    }
    return location.pathname.startsWith(path);
  };

  return (
    <div className="min-h-screen flex flex-col bg-gradient-to-br from-slate-50 to-slate-100">
      {/* Header */}
      <header className="sticky top-0 z-50 backdrop-blur-lg bg-white/80 border-b border-slate-200">
        <nav className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
          <Link to="/" className="flex items-center gap-2 group">
            <div className="size-8 bg-gradient-to-br from-indigo-600 to-purple-600 rounded-lg flex items-center justify-center transform group-hover:scale-105 transition-transform">
              <Code2 className="size-5 text-white" />
            </div>
            <span className="text-xl font-semibold bg-gradient-to-r from-indigo-600 to-purple-600 bg-clip-text text-transparent">
              ZigCSS
            </span>
          </Link>

          <div className="hidden md:flex items-center gap-1">
            <Link
              to="/"
              className={`px-4 py-2 rounded-lg transition-colors ${
                isActive("/") && !isActive("/playground")
                  ? "bg-indigo-100 text-indigo-700"
                  : "text-slate-600 hover:text-slate-900 hover:bg-slate-100"
              }`}
            >
              Home
            </Link>
            <Link
              to="/features"
              className={`px-4 py-2 rounded-lg transition-colors ${
                isActive("/features")
                  ? "bg-indigo-100 text-indigo-700"
                  : "text-slate-600 hover:text-slate-900 hover:bg-slate-100"
              }`}
            >
              Features
            </Link>
            <Link
              to="/playground"
              className={`px-4 py-2 rounded-lg transition-colors ${
                isActive("/playground")
                  ? "bg-indigo-100 text-indigo-700"
                  : "text-slate-600 hover:text-slate-900 hover:bg-slate-100"
              }`}
            >
              Playground (offline)
            </Link>
            <Link
              to="/docs"
              className={`px-4 py-2 rounded-lg transition-colors ${
                isActive("/docs")
                  ? "bg-indigo-100 text-indigo-700"
                  : "text-slate-600 hover:text-slate-900 hover:bg-slate-100"
              }`}
            >
              Docs
            </Link>
            <Link
              to="/getting-started"
              className={`px-4 py-2 rounded-lg transition-colors ${
                isActive("/getting-started")
                  ? "bg-indigo-100 text-indigo-700"
                  : "text-slate-600 hover:text-slate-900 hover:bg-slate-100"
              }`}
            >
              Get Started
            </Link>
          </div>

          <a
            href="https://github.com/vyakymenko/zigcss"
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center gap-2 px-4 py-2 rounded-lg bg-slate-900 text-white hover:bg-slate-800 transition-colors"
          >
            <Github className="size-4" />
            <span className="hidden sm:inline">GitHub</span>
          </a>
        </nav>
      </header>

      {/* Main Content */}
      <main className="flex-1">
        <Outlet />
      </main>

      {/* Footer */}
      <footer className="border-t border-slate-200 bg-white/50 backdrop-blur-sm">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="flex flex-col md:flex-row justify-between items-center gap-4">
            <div className="flex items-center gap-2">
              <Code2 className="size-5 text-indigo-600" />
              <span className="text-slate-600">
                © 2026 ZigCSS. Experimental recovery project.
              </span>
            </div>
            <div className="flex items-center gap-6">
              <a
                href="https://github.com/vyakymenko/zigcss"
                target="_blank"
                rel="noopener noreferrer"
                className="text-slate-600 hover:text-indigo-600 transition-colors"
              >
                GitHub
              </a>
              <Link
                to="/docs"
                className="text-slate-600 hover:text-indigo-600 transition-colors"
              >
                Documentation
              </Link>
              <Link
                to="/getting-started"
                className="text-slate-600 hover:text-indigo-600 transition-colors"
              >
                Get Started
              </Link>
            </div>
          </div>
        </div>
      </footer>
    </div>
  );
}
