import { Outlet, Link, useLocation } from "react-router";
import { Book } from "lucide-react";

const SIDEBAR = [
  {
    text: "Recovery documentation",
    icon: Book,
    items: [
      { text: "Current status", link: "/docs/guide/status" },
      { text: "CSS compatibility", link: "/docs/guide/css-compatibility" },
      { text: "Format compatibility", link: "/docs/guide/format-compatibility" },
      { text: "Build from source", link: "/docs/guide/build-from-source" },
      { text: "Recovery CLI", link: "/docs/guide/recovery-cli" },
    ],
  },
] as const;

export function DocsLayout() {
  const location = useLocation();

  return (
    <div className="min-h-screen py-8 px-4 sm:px-6 lg:px-8">
      <div className="max-w-7xl mx-auto flex flex-col lg:flex-row gap-8">
        <aside className="lg:w-64 flex-shrink-0">
          <nav className="sticky top-24 space-y-6">
            {SIDEBAR.map((section) => {
              const Icon = section.icon;
              return (
                <div key={section.text}>
                  <div className="flex items-center gap-2 mb-2 text-slate-700 font-semibold">
                    <Icon className="size-4 text-indigo-600" />
                    {section.text}
                  </div>
                  <ul className="space-y-0.5">
                    {section.items.map((item) => {
                      const isActive = location.pathname === item.link;
                      return (
                        <li key={item.link}>
                          <Link
                            to={item.link}
                            className={`block px-3 py-2 rounded-lg text-sm transition-colors ${
                              isActive
                                ? "bg-indigo-100 text-indigo-700 font-medium"
                                : "text-slate-600 hover:text-slate-900 hover:bg-slate-100"
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
