import { Link } from "react-router";
import type { ReactNode } from "react";
import { AlertTriangle, CheckCircle2, CircleOff, FlaskConical } from "lucide-react";
import capabilityMetadata from "../../data/capabilities.json";

const capabilities = capabilityMetadata.capabilities;

function StatusIcon({ statusKind }: { statusKind: string }) {
  if (statusKind === "verified") return <CheckCircle2 className="size-5 text-[#476f14]" />;
  if (statusKind === "disabled" || statusKind === "unavailable") return <CircleOff className="size-5 text-[#7b493f]" />;
  return <FlaskConical className="size-5 text-[#8a670f]" />;
}

function InlineBehavior({ value }: { value: string }) {
  const tokens = /`([^`\n]+)`|\[([^\]\n]+)\]\(([^)\s]+)\)/g;
  const parts: ReactNode[] = [];
  let cursor = 0;

  for (const match of value.matchAll(tokens)) {
    const index = match.index;
    if (index > cursor) parts.push(value.slice(cursor, index));

    const key = `${index}-${match[0]}`;
    if (match[1] !== undefined) {
      parts.push(
        <code key={key} className="break-all bg-[#e3dfd4] px-1 py-0.5 font-mono text-sm text-[#273029] sm:break-normal">
          {match[1]}
        </code>,
      );
    } else {
      const label = match[2] ?? "";
      const href = match[3] ?? "";
      const isInternal = href.startsWith("/") && !href.startsWith("//") && !href.includes("\\");
      let isSafeExternal = false;
      try {
        const url = new URL(href);
        isSafeExternal = url.protocol === "https:" && url.username === "" && url.password === "";
      } catch {
        // Invalid and unsupported link targets stay visible as literal source text.
      }

      if (isInternal) {
        parts.push(<Link key={key} to={href} className="font-medium text-[#36570d] underline underline-offset-2">{label}</Link>);
      } else if (isSafeExternal) {
        parts.push(
          <a key={key} href={href} target="_blank" rel="noopener noreferrer" className="font-medium text-[#36570d] underline underline-offset-2">
            {label}
          </a>,
        );
      } else {
        parts.push(match[0]);
      }
    }

    cursor = index + match[0].length;
  }

  if (cursor < value.length) parts.push(value.slice(cursor));
  return parts;
}

function MobileColumnLabel({ children }: { children: string }) {
  return (
    <span
      aria-hidden="true"
      data-mobile-column-label={children}
      className="mb-2 block font-mono text-[0.68rem] uppercase tracking-[0.14em] text-[#6c736b] sm:hidden"
    >
      {children}
    </span>
  );
}

export function Features() {
  return (
    <div className="min-h-screen bg-[#f3f0e7] px-5 py-14 text-[#172019] sm:px-8 md:py-20 lg:px-10">
      <div className="mx-auto max-w-7xl">
        <div className="mb-12 max-w-4xl">
          <div className="mb-5 inline-flex items-center gap-2 border border-[#d0a43f] bg-[#fff2bf] px-3 py-1.5 font-mono text-xs uppercase tracking-[0.16em] text-[#5e470f]">
            <AlertTriangle className="size-4" />
            Stable 0.6.0 + 0.7.0-rc.1 source · bounded capabilities
          </div>
          <h1 className="display-type text-5xl tracking-[-0.05em] sm:text-6xl">Current capability status</h1>
          <p className="mt-6 max-w-3xl text-xl leading-8 text-[#5f675f]">
            This site separates published stable 0.6.0 delivery from bounded current-source evidence. That evidence belongs to unpublished candidate 0.7.0-rc.1. It is an evidence-linked boundary report, not a compatibility promise for every plugin, framework, or future oracle version.
          </p>
          <p className="mt-4 max-w-3xl font-mono text-xs leading-6 text-[#677067]">
            The table mixes explicitly labeled published-stable rows with current-source evidence. REL-010 promotes only the stable 0.6.0 rows; rows whose contract says current, source-checkout, or Unreleased remain Unreleased even after their gates pass.
          </p>
        </div>

        <div className="overflow-hidden border border-[#bdb8aa] bg-[#f9f6ed] sm:overflow-x-auto">
          <table className="block w-full max-w-full text-left sm:table">
            <thead className="hidden border-b border-[#334139] bg-[#101914] text-[#f7f3e8] sm:table-header-group">
              <tr>
                <th className="p-5 font-mono text-xs uppercase tracking-[0.14em]">Surface</th>
                <th className="p-5 font-mono text-xs uppercase tracking-[0.14em]">Status</th>
                <th className="p-5 font-mono text-xs uppercase tracking-[0.14em]">Current contract</th>
              </tr>
            </thead>
            <tbody className="block space-y-3 bg-[#e8e3d8] p-3 sm:table-row-group sm:space-y-0 sm:bg-transparent sm:p-0">
              {capabilities.map(capability => (
                <tr key={capability.id} className="block border border-[#cfc9ba] bg-[#f9f6ed] p-4 align-top sm:table-row sm:border-x-0 sm:border-t-0 sm:border-b-[#d6d1c5] sm:bg-transparent sm:p-0 sm:last:border-b-0">
                  <td className="block p-0 sm:table-cell sm:p-5">
                    <MobileColumnLabel>Surface</MobileColumnLabel>
                    <span className="font-semibold">{capability.surface}</span>
                  </td>
                  <td className="mt-4 block border-t border-[#ddd7ca] p-0 pt-4 sm:table-cell sm:border-t-0 sm:p-5">
                    <MobileColumnLabel>Status</MobileColumnLabel>
                    <span className="inline-flex max-w-full items-start gap-2 whitespace-normal sm:items-center sm:whitespace-nowrap">
                      <StatusIcon statusKind={capability.statusKind} />
                      {capability.status}
                    </span>
                  </td>
                  <td className="mt-4 block min-w-0 border-t border-[#ddd7ca] p-0 pt-4 leading-7 text-[#5f675f] sm:table-cell sm:border-t-0 sm:p-5">
                    <MobileColumnLabel>Current contract</MobileColumnLabel>
                    <InlineBehavior value={capability.behavior} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-10 flex flex-col gap-4 sm:flex-row">
          <Link to="/docs/guide/builder-integrations" className="border border-[#101914] px-6 py-3 text-center font-semibold hover:bg-[#e1ddd1]">
            Run builder integrations
          </Link>
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
