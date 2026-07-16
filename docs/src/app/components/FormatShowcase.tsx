import { useState } from "react";
import { ArrowRight, CheckCircle2, CircleOff, Sparkles } from "lucide-react";
import { Link } from "react-router";

type FormatExample = {
  id: "css" | "scss" | "sass" | "less" | "stylus";
  label: string;
  extension: string;
  input: string;
  pipeline: string;
  note: string;
};

const formatExamples: readonly FormatExample[] = [
  {
    id: "css",
    label: "CSS",
    extension: ".css",
    input: `:root {
  --accent: #b7f34a;
}

.button {
  color: #101914;
  background: var(--accent);
}`,
    pipeline: "CSS → ZigCSS → compact CSS",
    note: "This is the native ZigCSS path: parsed, emitted, and independently checked as CSS.",
  },
  {
    id: "scss",
    label: "SCSS",
    extension: ".scss",
    input: `$accent: #b7f34a;

.button {
  background: $accent;

  &:hover {
    filter: brightness(1.08);
  }
}`,
    pipeline: "SCSS → Sass compiler → CSS → ZigCSS",
    note: "ZigCSS does not expand variables or nesting. Compile SCSS to CSS before handing it to ZigCSS.",
  },
  {
    id: "sass",
    label: "Sass",
    extension: ".sass",
    input: `$accent: #b7f34a

.button
  background: $accent
  &:hover
    filter: brightness(1.08)`,
    pipeline: "Indented Sass → Sass compiler → CSS → ZigCSS",
    note: "Indented Sass is a separate preprocessor grammar and is rejected before ZigCSS emits output.",
  },
  {
    id: "less",
    label: "Less",
    extension: ".less",
    input: `@accent: #b7f34a;

.button {
  background: @accent;

  &:hover {
    filter: brightness(1.08);
  }
}`,
    pipeline: "Less → Less compiler → CSS → ZigCSS",
    note: "Less variables and mixins need the Less compiler first. ZigCSS accepts the resulting CSS.",
  },
  {
    id: "stylus",
    label: "Stylus",
    extension: ".styl",
    input: `accent = #b7f34a

.button
  background accent
  &:hover
    filter brightness(1.08)`,
    pipeline: "Stylus → Stylus compiler → CSS → ZigCSS",
    note: "Stylus syntax is not a ZigCSS input format. Preprocess it to CSS before compilation.",
  },
] as const;

export function FormatShowcase() {
  const [selectedId, setSelectedId] = useState<FormatExample["id"]>("css");
  const selected = formatExamples.find(example => example.id === selectedId) ?? formatExamples[0];
  const isCss = selected.id === "css";

  return (
    <section className="site-grid bg-[#101914] text-[#f7f3e8]" aria-labelledby="format-lab-title">
      <div className="mx-auto max-w-7xl px-5 py-20 sm:px-8 md:py-28 lg:px-10">
        <div className="grid gap-8 lg:grid-cols-[0.75fr_1.25fr] lg:items-end">
          <div>
            <p className="inline-flex items-center gap-2 font-mono text-xs uppercase tracking-[0.2em] text-[#b7f34a]">
              <Sparkles className="size-4" />
              Input / output lab
            </p>
            <h2 id="format-lab-title" className="display-type mt-4 max-w-xl text-4xl leading-[1.02] tracking-[-0.045em] sm:text-5xl">
              Five syntaxes. One honest boundary.
            </h2>
          </div>
          <p className="max-w-2xl text-lg leading-8 text-[#aeb9b0] lg:justify-self-end">
            Select a stylesheet format to see exactly what enters ZigCSS—and whether the compiler is allowed to emit anything at all.
          </p>
        </div>

        <div className="mt-10 border border-[#3b493f] bg-[#152019] shadow-[12px_12px_0_0_#080d0a]">
          <div className="flex flex-wrap border-b border-[#3b493f] bg-[#0d1510]" role="tablist" aria-label="Stylesheet input formats">
            {formatExamples.map(example => (
              <button
                key={example.id}
                type="button"
                role="tab"
                aria-selected={selected.id === example.id}
                aria-controls="format-example-panel"
                onClick={() => setSelectedId(example.id)}
                className={`border-b-2 px-5 py-4 font-mono text-sm transition sm:px-7 ${
                  selected.id === example.id
                    ? "border-[#b7f34a] bg-[#1d2a21] text-[#d4ff86]"
                    : "border-transparent text-[#89958c] hover:bg-[#18231c] hover:text-[#f7f3e8]"
                }`}
              >
                {example.label}
              </button>
            ))}
          </div>

          <div id="format-example-panel" role="tabpanel" className="grid lg:grid-cols-2">
            <div className="border-b border-[#3b493f] p-5 sm:p-7 lg:border-b-0 lg:border-r">
              <div className="flex items-center justify-between gap-4">
                <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#89958c]">Input {selected.extension}</p>
                <span className="border border-[#46544a] px-2 py-1 font-mono text-[11px] text-[#aeb9b0]">{selected.label}</span>
              </div>
              {isCss ? (
                <pre className="mt-5 min-h-64 overflow-x-auto bg-[#0a110d] p-5 text-sm leading-6 text-[#e0e6e1]"><code data-language="css">{`:root {
  --accent: #b7f34a;
}

.button {
  color: #101914;
  background: var(--accent);
}`}</code></pre>
              ) : (
                <pre className="mt-5 min-h-64 overflow-x-auto bg-[#0a110d] p-5 text-sm leading-6 text-[#e0e6e1]"><code data-language="text">{selected.input}</code></pre>
              )}
            </div>

            <div className="p-5 sm:p-7" aria-live="polite">
              <div className="flex items-center justify-between gap-4">
                <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#89958c]">ZigCSS result</p>
                <span className={`inline-flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.12em] ${isCss ? "text-[#b7f34a]" : "text-[#e9a995]"}`}>
                  {isCss ? <CheckCircle2 className="size-4" /> : <CircleOff className="size-4" />}
                  {isCss ? "CSS emitted" : "Not supported"}
                </span>
              </div>

              {isCss ? (
                <pre className="mt-5 min-h-64 overflow-x-auto bg-[#0a110d] p-5 text-sm leading-6 text-[#d4ff86]"><code data-language="css">{`:root{--accent:#b7f34a}.button{color:#101914;background:var(--accent)}`}</code></pre>
              ) : (
                <div className="mt-5 flex min-h-64 flex-col justify-between border border-[#6a453b] bg-[#211713] p-5">
                  <div>
                    <p className="font-mono text-xs uppercase tracking-[0.18em] text-[#e9a995]">No CSS emitted</p>
                    <p className="mt-4 max-w-md text-xl font-semibold text-[#f7f3e8]">A preprocessor must translate this syntax first.</p>
                    <p className="mt-3 max-w-lg leading-7 text-[#c7b4ad]">{selected.note}</p>
                  </div>
                  <code className="mt-8 block overflow-x-auto whitespace-nowrap border-t border-[#6a453b] pt-4 font-mono text-xs text-[#f4c3b3]">
                    {selected.pipeline}
                  </code>
                </div>
              )}

              {isCss && <p className="mt-5 text-sm leading-6 text-[#9eaba1]">{selected.note}</p>}
            </div>
          </div>
        </div>

        <div className="mt-9 flex flex-col gap-4 border-l-2 border-[#b7f34a] pl-5 sm:flex-row sm:items-center sm:justify-between">
          <p className="max-w-3xl text-sm leading-6 text-[#9eaba1]">
            ZigCSS is a CSS compiler, not a bundled preprocessor stack. Adapter coverage can grow later without weakening today&apos;s input contract.
          </p>
          <Link to="/docs/guide/format-compatibility" className="inline-flex flex-shrink-0 items-center gap-2 font-semibold text-[#b7f34a] hover:underline">
            Format policy <ArrowRight className="size-4" />
          </Link>
        </div>
      </div>
    </section>
  );
}
