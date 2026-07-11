import { Link } from "react-router";
import { AlertTriangle, CheckCircle2, CircleOff, FlaskConical } from "lucide-react";

const capabilities = [
  {
    surface: "Basic CSS parsing and emission",
    status: "Experimental",
    detail: "Useful for characterization, with known selector, delimiter, and at-rule defects.",
  },
  {
    surface: "Compact emission (--minify)",
    status: "Experimental",
    detail: "Whitespace-only emission mode; it does not run optimizer transforms.",
  },
  {
    surface: "Output path planning",
    status: "Verified boundary",
    detail: "Rejects input aliases and duplicate batch destinations before writes.",
  },
  {
    surface: "Optimizer, prefixing, critical CSS",
    status: "Disabled",
    detail: "Known unsafe transforms are unreachable from the recovery CLI and stable code generation path.",
  },
  {
    surface: "Source maps and browser targets",
    status: "Unavailable",
    detail: "Requests fail explicitly until real mappings and validated target data exist.",
  },
  {
    surface: "Alternate format adapters",
    status: "Experimental / CLI-disabled",
    detail: "Legacy SCSS, SASS, LESS, Stylus, PostCSS, CSS Modules, and CSS-in-JS adapters remain internal.",
  },
  {
    surface: "LSP",
    status: "Experimental",
    detail: "The server still shares the legacy parser and is not a stable editor contract.",
  },
  {
    surface: "Public compile API and playground",
    status: "Disabled",
    detail: "The static documentation server returns HTTP 503 for compile requests.",
  },
] as const;

function StatusIcon({ status }: { status: string }) {
  if (status === "Verified boundary") return <CheckCircle2 className="size-5 text-emerald-700" />;
  if (status === "Disabled" || status === "Unavailable") return <CircleOff className="size-5 text-slate-500" />;
  return <FlaskConical className="size-5 text-amber-700" />;
}

export function Features() {
  return (
    <div className="min-h-screen py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-6xl mx-auto">
        <div className="mb-12">
          <div className="inline-flex items-center gap-2 text-amber-800 bg-amber-100 rounded-full px-4 py-2 mb-5">
            <AlertTriangle className="size-4" />
            Experimental compiler
          </div>
          <h1 className="text-4xl mb-4">Current capability status</h1>
          <p className="text-xl text-slate-600 max-w-3xl">
            This table describes the recovery branch as it behaves today. It is a boundary report, not a compatibility promise.
          </p>
        </div>

        <div className="overflow-x-auto bg-white rounded-xl border border-slate-200 shadow-sm">
          <table className="w-full text-left">
            <thead className="bg-slate-100 border-b border-slate-200">
              <tr>
                <th className="p-4">Surface</th>
                <th className="p-4">Status</th>
                <th className="p-4">Current contract</th>
              </tr>
            </thead>
            <tbody>
              {capabilities.map(capability => (
                <tr key={capability.surface} className="border-b border-slate-100 align-top">
                  <td className="p-4 font-medium">{capability.surface}</td>
                  <td className="p-4">
                    <span className="inline-flex items-center gap-2 whitespace-nowrap">
                      <StatusIcon status={capability.status} />
                      {capability.status}
                    </span>
                  </td>
                  <td className="p-4 text-slate-600">{capability.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-10 flex flex-col sm:flex-row gap-4">
          <Link to="/docs/guide/status" className="px-6 py-3 rounded-lg bg-indigo-700 text-white text-center">
            Read known limitations
          </Link>
          <Link to="/getting-started" className="px-6 py-3 rounded-lg border border-slate-300 bg-white text-center">
            Build from source
          </Link>
        </div>
      </div>
    </div>
  );
}
