import { Link, Outlet, useLocation } from "react-router";

const navigation = [
  { label: "Boot", path: "/" },
  { label: "Convergence", path: "/#convergence" },
  { label: "Manifesto", path: "/#manifesto" },
  { label: "Lab", path: "/#formats" },
  { label: "Docs", path: "/docs" },
  { label: "Install", path: "/getting-started" },
] as const;

export function Root() {
  const location = useLocation();

  const isActive = (path: string) => {
    const [pathname, hash = ""] = path.split("#");
    if (hash) return location.pathname === pathname && location.hash === `#${hash}`;
    return path === "/" ? location.pathname === "/" && !location.hash : location.pathname.startsWith(path);
  };

  return (
    <div className="flex min-h-screen flex-col overflow-x-clip bg-[#0b110d] text-[#eef5ec]">
      <header className="sticky top-0 z-50 border-b border-[#b7f34a]/15 bg-[#0b110d]/94 text-[#eef5ec] backdrop-blur-md">
        <nav className="mx-auto flex h-16 max-w-[96rem] items-center gap-4 px-4 sm:px-8 lg:px-12" aria-label="Primary navigation">
          <Link to="/" className="group flex flex-shrink-0 items-center gap-3 font-mono" aria-label="ZigCSS home">
            <span className="flex size-8 items-center justify-center border border-[#b7f34a]/50 text-[#b7f34a] transition group-hover:bg-[#b7f34a] group-hover:text-[#0b110d]" aria-hidden="true">Z</span>
            <span className="text-sm font-semibold tracking-[-0.025em] sm:text-base">ZigCSS<span className="block-caret ml-1 inline-block text-[#b7f34a]" /></span>
          </Link>

          <div className="ml-auto flex min-w-0 items-center overflow-x-auto font-mono">
            {navigation.map(item => (
              <Link
                key={item.path}
                to={item.path}
                aria-current={isActive(item.path) ? "page" : undefined}
                className={`whitespace-nowrap px-3 py-2 text-[10px] uppercase tracking-[0.1em] transition sm:px-4 sm:text-xs ${
                  isActive(item.path)
                    ? "text-[#b7f34a]"
                    : "text-[#748272] hover:text-[#eef5ec]"
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
            className="terminal-link hidden flex-shrink-0 border border-[#b7f34a]/20 px-3 py-2 font-mono text-xs text-[#aab5a8] hover:border-[#b7f34a]/60 hover:text-[#b7f34a] md:block"
          >
            GitHub
          </a>
        </nav>
      </header>

      <main className="flex-1">
        <Outlet />
      </main>

      <footer className="border-t border-[#b7f34a]/15 bg-[#080d0a] text-[#7f8d7d]">
        <div className="mx-auto max-w-[96rem] px-5 py-16 sm:px-8 lg:px-12">
          <div className="grid gap-10 md:grid-cols-[1fr_auto] md:items-end">
            <div>
              <p className="gate-label">END OF TRANSMISSION</p>
              <p className="display-type mt-5 max-w-3xl text-4xl leading-[0.9] tracking-[-0.055em] text-[#eef5ec] sm:text-6xl">
                Compile CSS. <span className="text-[#b7f34a]">Keep the meaning.</span>
              </p>
            </div>
            <nav className="flex flex-wrap gap-x-6 gap-y-3 font-mono text-xs" aria-label="Footer navigation">
              <Link to="/docs/guide/status" className="terminal-link hover:text-[#b7f34a]">Status</Link>
              <Link to="/docs/guide/css-compatibility" className="terminal-link hover:text-[#b7f34a]">Compatibility</Link>
              <a href="https://www.npmjs.com/package/zigcss" target="_blank" rel="noopener noreferrer" className="terminal-link hover:text-[#b7f34a]">npm</a>
              <a href="https://github.com/vyakymenko/zigcss" target="_blank" rel="noopener noreferrer" className="terminal-link hover:text-[#b7f34a]">GitHub</a>
            </nav>
          </div>
          <div className="mt-12 flex flex-col gap-3 border-t border-[#b7f34a]/12 pt-5 font-mono text-[10px] uppercase tracking-[0.12em] sm:flex-row sm:items-center sm:justify-between">
            <p>MIT · deterministic · fail-closed <span className="block-caret ml-2 inline-block text-[#b7f34a]" aria-hidden="true" /></p>
            <p className="text-[#ffc978]">Experimental · evaluate before production</p>
          </div>
        </div>
      </footer>
    </div>
  );
}
