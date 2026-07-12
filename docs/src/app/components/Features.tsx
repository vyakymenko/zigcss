import { Link } from "react-router";
import { AlertTriangle, CheckCircle2, CircleOff, FlaskConical } from "lucide-react";
import capabilityMetadata from "../../data/capabilities.json";

const capabilities = capabilityMetadata.capabilities;

function StatusIcon({ statusKind }: { statusKind: string }) {
  if (statusKind === "verified") return <CheckCircle2 className="size-5 text-emerald-700" />;
  if (statusKind === "disabled" || statusKind === "unavailable") return <CircleOff className="size-5 text-slate-500" />;
  return <FlaskConical className="size-5 text-amber-700" />;
}

function InlineBehavior({ value }: { value: string }) {
  return value.split(/(`[^`]+`)/g).filter(Boolean).map((part, index) =>
    part.startsWith("`")
      ? <code key={index} className="rounded bg-slate-100 px-1 py-0.5 text-sm text-slate-800">{part.slice(1, -1)}</code>
      : part
  );
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
                <tr key={capability.id} className="border-b border-slate-100 align-top">
                  <td className="p-4 font-medium">{capability.surface}</td>
                  <td className="p-4">
                    <span className="inline-flex items-center gap-2 whitespace-nowrap">
                      <StatusIcon statusKind={capability.statusKind} />
                      {capability.status}
                    </span>
                  </td>
                  <td className="p-4 text-slate-600"><InlineBehavior value={capability.behavior} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-10 flex flex-col sm:flex-row gap-4">
          <Link to="/docs/guide/css-compatibility" className="px-6 py-3 rounded-lg bg-indigo-700 text-white text-center">
            Read CSS compatibility
          </Link>
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
