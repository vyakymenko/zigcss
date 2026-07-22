import { createBrowserRouter, Navigate } from "react-router";
import { Root } from "./components/Root";

export const router = createBrowserRouter(
  [
    {
      path: "/",
      Component: Root,
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
  { basename: "/zigcss" }
);
