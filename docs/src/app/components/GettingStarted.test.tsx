import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import { BrowserRouter } from "react-router";
import { GettingStarted } from "./GettingStarted";

function wrap(ui: React.ReactElement) {
  return <BrowserRouter>{ui}</BrowserRouter>;
}

describe("GettingStarted", () => {
  it("renders Getting Started heading", () => {
    render(wrap(<GettingStarted />));
    expect(screen.getByRole("heading", { name: /getting started/i })).toBeInTheDocument();
  });

  it("renders Installation section", () => {
    render(wrap(<GettingStarted />));
    expect(screen.getByRole("heading", { name: /installation/i })).toBeInTheDocument();
  });

  it("shows npm install command", () => {
    render(wrap(<GettingStarted />));
    expect(screen.getByText(/npm install -g zigcss/)).toBeInTheDocument();
  });

  it("shows Homebrew install", () => {
    render(wrap(<GettingStarted />));
    expect(screen.getByText(/brew tap vyakymenko\/zigcss/)).toBeInTheDocument();
  });
});
