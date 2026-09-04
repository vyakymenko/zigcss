import { Outlet, Link, useLocation } from "react-router";
import { Book } from "lucide-react";

const SIDEBAR = [
  {
    text: "Package documentation",
    icon: Book,
    items: [
      { text: "Current status", link: "/docs/guide/status" },
      { text: "CSS compatibility", link: "/docs/guide/css-compatibility" },
      { text: "Format compatibility", link: "/docs/guide/format-compatibility" },
      { text: "CSS Modules subset", link: "/docs/guide/css-modules" },
      { text: "Build from source", link: "/docs/guide/build-from-source" },
      { text: "Builder integrations", link: "/docs/guide/builder-integrations" },
      { text: "Recovery CLI", link: "/docs/guide/recovery-cli" },
    ],
  },
] as const;

export function DocsLayout() {
  const location = useLocation();
  const currentPath = location.pathname === "/" ? "/" : location.pathname.replace(/\/+$/, "");

  return (
    <div className="min-h-screen bg-[#f3f0e7] px-5 py-10 text-[#172019] sm:px-8 lg:px-10">
      <div className="mx-auto flex max-w-7xl flex-col gap-9 lg:flex-row">
        <aside className="lg:w-64 flex-shrink-0">
          <nav className="sticky top-24 space-y-6 border-t-4 border-[#b7f34a] bg-[#101914] p-5 text-[#f7f3e8]">
            {SIDEBAR.map((section) => {
              const Icon = section.icon;
              return (
                <div key={section.text}>
                  <div className="mb-3 flex items-center gap-2 font-semibold">
                    <Icon className="size-4 text-[#b7f34a]" />
                    {section.text}
                  </div>
                  <ul className="space-y-0.5">
                    {section.items.map((item) => {
                      const isActive = currentPath === item.link;
                      return (
                        <li key={item.link}>
                          <Link
                            to={item.link}
                            aria-current={isActive ? "page" : undefined}
                            className={`block px-3 py-2 text-sm transition-colors ${
                              isActive
                                ? "bg-[#b7f34a] font-medium text-[#101914]"
                                : "text-[#aeb9b0] hover:bg-[#263229] hover:text-white"
                            }`}
                          >
                            {item.text}
                          </Link>
                        </li>
                      );
                    })}
                  </ul>
                </div>
              );
            })}
          </nav>
        </aside>
        <div className="flex-1 min-w-0">
          <Outlet />
        </div>
      </div>
    </div>
  );
}
