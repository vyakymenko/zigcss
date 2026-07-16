import { createBrowserRouter, Navigate } from "react-router";
import { Root } from "./components/Root";
import { Home } from "./components/Home";
import { Playground } from "./components/Playground";
import { GettingStarted } from "./components/GettingStarted";
import { Features } from "./components/Features";
import { NotFound } from "./components/NotFound";
import { DocsLayout } from "./components/docs/DocsLayout";
import { DocView } from "./components/docs/DocView";

export const router = createBrowserRouter(
  [
    {
      path: "/",
      Component: Root,
      children: [
        { index: true, Component: Home },
        { path: "playground", Component: Playground },
        {
          path: "docs",
          Component: DocsLayout,
          children: [
            { index: true, element: <Navigate to="guide/status" replace /> },
            { path: "*", Component: DocView },
          ],
        },
        { path: "getting-started", Component: GettingStarted },
        { path: "features", Component: Features },
        { path: "*", Component: NotFound },
      ],
    },
  ],
  { basename: "/zigcss" }
);
