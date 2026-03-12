import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router";
import { Features } from "./Features";

function wrap(ui: React.ReactElement) {
  return <BrowserRouter>{ui}</BrowserRouter>;
}

describe("Features", () => {
  it("renders Powerful Features heading", () => {
    render(wrap(<Features />));
    expect(screen.getByRole("heading", { name: /powerful features/i })).toBeInTheDocument();
  });

  it("renders How ZigCSS Compares section", () => {
    render(wrap(<Features />));
    expect(screen.getByText(/how zigcss compares/i)).toBeInTheDocument();
  });

  it("has Get Started link", () => {
    render(wrap(<Features />));
    expect(screen.getByRole("link", { name: /get started/i })).toBeInTheDocument();
  });

  it("has Try Playground link", () => {
    render(wrap(<Features />));
    expect(screen.getByRole("link", { name: /try playground/i })).toBeInTheDocument();
  });
});
