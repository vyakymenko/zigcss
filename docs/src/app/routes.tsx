import { createBrowserRouter, Navigate } from "react-router";
import { Root } from "./components/Root";

export function RouteFallback() {
  return (
    <div
      className="flex min-h-screen items-center justify-center bg-[#0b110d] px-5 text-[#eef5ec]"
      role="status"
      aria-label="Loading ZigCSS"
      aria-live="polite"
    >
      <div className="w-full max-w-md border border-[#b7f34a]/25 bg-[#080d0a] p-6 font-mono shadow-[8px_8px_0_rgba(183,243,74,0.08)]">
        <div className="flex items-center gap-3">
          <span className="flex size-9 items-center justify-center border border-[#b7f34a]/50 text-[#b7f34a]" aria-hidden="true">Z</span>
          <strong className="text-sm tracking-[-0.025em]">ZigCSS<span className="block-caret ml-1 inline-block text-[#b7f34a]" aria-hidden="true" /></strong>
        </div>
        <p className="mt-6 text-[10px] uppercase tracking-[0.16em] text-[#8d9a8b]">Loading route <span className="text-[#b7f34a]">···</span></p>
      </div>
    </div>
  );
}

export const router = createBrowserRouter(
  [
    {
      path: "/",
      Component: Root,
      HydrateFallback: RouteFallback,
      children: [
        {
          index: true,
          lazy: async () => ({ Component: (await import("./components/Home")).Home }),
        },
        {
          path: "playground",
          lazy: async () => ({ Component: (await import("./components/Playground")).Playground }),
        },
        {
          path: "docs",
          lazy: async () => ({ Component: (await import("./components/docs/DocsLayout")).DocsLayout }),
          children: [
            { index: true, element: <Navigate to="guide/status" replace /> },
            {
              path: "*",
              lazy: async () => ({ Component: (await import("./components/docs/DocView")).DocView }),
            },
          ],
        },
        {
          path: "getting-started",
          lazy: async () => ({ Component: (await import("./components/GettingStarted")).GettingStarted }),
        },
        {
          path: "features",
          lazy: async () => ({ Component: (await import("./components/Features")).Features }),
        },
        {
          path: "*",
          lazy: async () => ({ Component: (await import("./components/NotFound")).NotFound }),
        },
      ],
    },
  ],
  { basename: "/zigcss/" }
);
