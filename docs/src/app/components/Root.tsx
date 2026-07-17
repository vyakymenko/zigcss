import { Outlet, Link, useLocation } from "react-router";
import { Braces, Github } from "lucide-react";

const navigation = [
  { label: "Overview", path: "/" },
  { label: "CSS support", path: "/features" },
  { label: "Docs", path: "/docs" },
  { label: "Get started", path: "/getting-started" },
] as const;

export function Root() {
  const location = useLocation();

  const isActive = (path: string) =>
    path === "/" ? location.pathname === "/" : location.pathname.startsWith(path);

  return (
    <div className="flex min-h-screen flex-col overflow-x-clip bg-[#f3f0e7] text-[#172019]">
      <header className="sticky top-0 z-50 border-b border-[#344139] bg-[#101914]/95 text-[#f7f3e8] backdrop-blur">
        <nav className="mx-auto flex h-16 max-w-7xl items-center gap-4 px-4 sm:px-8 lg:px-10" aria-label="Primary navigation">
          <Link to="/" className="group flex flex-shrink-0 items-center gap-3" aria-label="ZigCSS home">
            <span className="flex size-9 items-center justify-center bg-[#b7f34a] text-[#101914] transition-transform group-hover:-rotate-3">
              <Braces className="size-5" />
            </span>
            <span className="display-type text-xl tracking-[-0.035em]">ZigCSS</span>
          </Link>

          <div className="ml-auto flex min-w-0 items-center gap-1 overflow-x-auto">
            {navigation.map(item => (
              <Link
                key={item.path}
                to={item.path}
                className={`whitespace-nowrap px-3 py-2 text-sm transition sm:px-4 ${
                  isActive(item.path)
                    ? "bg-[#263229] text-[#cfff75]"
                    : "text-[#aeb9b0] hover:text-white"
                }`}
              >
                {item.label}
              </Link>
            ))}
          </div>

          <a
            href="https://github.com/vyakymenko/zigcss"
            target="_blank"
            rel="noopener noreferrer"
            className="hidden flex-shrink-0 items-center gap-2 border border-[#526158] px-3 py-2 text-sm text-[#dce4dd] transition hover:border-[#b7f34a] hover:text-[#b7f34a] sm:flex"
          >
            <Github className="size-4" />
            GitHub
          </a>
        </nav>
      </header>

      <main className="flex-1">
        <Outlet />
      </main>

      <footer className="border-t border-[#344139] bg-[#101914] text-[#9daaa0]">
        <div className="mx-auto flex max-w-7xl flex-col gap-7 px-5 py-10 sm:px-8 md:flex-row md:items-center md:justify-between lg:px-10">
          <div>
            <div className="flex items-center gap-2 text-[#f7f3e8]">
              <Braces className="size-5 text-[#b7f34a]" />
              <span className="display-type text-lg">ZigCSS</span>
            </div>
            <p className="mt-2 text-sm">Experimental native CSS compiler · MIT licensed</p>
          </div>
          <div className="flex flex-wrap items-center gap-x-6 gap-y-3 text-sm">
            <Link to="/docs/guide/status" className="hover:text-[#b7f34a]">Status</Link>
            <Link to="/docs/guide/css-compatibility" className="hover:text-[#b7f34a]">Compatibility</Link>
            <Link to="/getting-started" className="hover:text-[#b7f34a]">Install</Link>
            <a href="https://github.com/vyakymenko/zigcss" target="_blank" rel="noopener noreferrer" className="hover:text-[#b7f34a]">GitHub</a>
          </div>
        </div>
      </footer>
    </div>
  );
}
