import { Link } from "react-router";
import { AlertTriangle, CheckCircle2, CircleOff, FlaskConical } from "lucide-react";
import capabilityMetadata from "../../data/capabilities.json";

const capabilities = capabilityMetadata.capabilities;

function StatusIcon({ statusKind }: { statusKind: string }) {
  if (statusKind === "verified") return <CheckCircle2 className="size-5 text-[#476f14]" />;
  if (statusKind === "disabled" || statusKind === "unavailable") return <CircleOff className="size-5 text-[#7b493f]" />;
  return <FlaskConical className="size-5 text-[#8a670f]" />;
}

function InlineBehavior({ value }: { value: string }) {
  return value.split(/(`[^`]+`)/g).filter(Boolean).map((part, index) =>
    part.startsWith("`")
      ? <code key={index} className="bg-[#e3dfd4] px-1 py-0.5 font-mono text-sm text-[#273029]">{part.slice(1, -1)}</code>
      : part
  );
}

export function Features() {
  return (
    <div className="min-h-screen bg-[#f3f0e7] px-5 py-14 text-[#172019] sm:px-8 md:py-20 lg:px-10">
      <div className="mx-auto max-w-7xl">
        <div className="mb-12 max-w-4xl">
          <div className="mb-5 inline-flex items-center gap-2 border border-[#d0a43f] bg-[#fff2bf] px-3 py-1.5 font-mono text-xs uppercase tracking-[0.16em] text-[#5e470f]">
            <AlertTriangle className="size-4" />
            Experimental compiler
          </div>
          <h1 className="display-type text-5xl tracking-[-0.05em] sm:text-6xl">Current capability status</h1>
          <p className="mt-6 max-w-3xl text-xl leading-8 text-[#5f675f]">
            This site describes the published native prerelease. It is an evidence-linked boundary report, not a compatibility promise for every plugin, framework, or future oracle version.
          </p>
          <p className="mt-4 max-w-3xl font-mono text-xs leading-6 text-[#6e776e]">
            The compatibility table below records the published NATIVE-009 native-graduated prerelease; GitHub prerelease and npm next publication are verified.
          </p>
        </div>

        <div className="overflow-x-auto border border-[#bdb8aa] bg-[#f9f6ed]">
          <table className="w-full text-left">
            <thead className="border-b border-[#334139] bg-[#101914] text-[#f7f3e8]">
              <tr>
                <th className="p-5 font-mono text-xs uppercase tracking-[0.14em]">Surface</th>
                <th className="p-5 font-mono text-xs uppercase tracking-[0.14em]">Status</th>
                <th className="p-5 font-mono text-xs uppercase tracking-[0.14em]">Current contract</th>
              </tr>
            </thead>
            <tbody>
              {capabilities.map(capability => (
                <tr key={capability.id} className="border-b border-[#d6d1c5] align-top last:border-b-0">
                  <td className="p-5 font-semibold">{capability.surface}</td>
                  <td className="p-5">
                    <span className="inline-flex items-center gap-2 whitespace-nowrap">
                      <StatusIcon statusKind={capability.statusKind} />
                      {capability.status}
                    </span>
                  </td>
                  <td className="p-5 leading-7 text-[#5f675f]"><InlineBehavior value={capability.behavior} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-10 flex flex-col gap-4 sm:flex-row">
          <Link to="/docs/guide/css-compatibility" className="bg-[#101914] px-6 py-3 text-center font-semibold text-[#f7f3e8] hover:bg-[#263229]">
            Read CSS compatibility
          </Link>
          <Link to="/docs/guide/status" className="border border-[#101914] px-6 py-3 text-center font-semibold hover:bg-[#e1ddd1]">
            Read known limitations
          </Link>
          <Link to="/getting-started" className="bg-[#b7f34a] px-6 py-3 text-center font-semibold">
            Install ZigCSS
          </Link>
        </div>
      </div>
    </div>
  );
}
