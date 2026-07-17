import { useState } from "react";
import { ArrowRight, CheckCircle2, Sparkles } from "lucide-react";
import { Link } from "react-router";
import formatExamples from "../../data/format-examples.json";

type FormatExample = (typeof formatExamples)[number];

export function FormatShowcase() {
  const [selectedId, setSelectedId] = useState<FormatExample["id"]>("css");
  const selected = formatExamples.find(example => example.id === selectedId) ?? formatExamples[0];

  return (
    <section id="formats" className="site-grid bg-[#101914] text-[#f7f3e8]" aria-labelledby="format-lab-title">
      <div className="mx-auto max-w-7xl px-5 py-20 sm:px-8 md:py-28 lg:px-10">
        <div className="grid gap-8 lg:grid-cols-[0.75fr_1.25fr] lg:items-end">
          <div>
            <p className="inline-flex items-center gap-2 font-mono text-xs uppercase tracking-[0.2em] text-[#b7f34a]">
              <Sparkles className="size-4" />
              Input / output lab
            </p>
            <h2 id="format-lab-title" className="display-type mt-4 max-w-xl text-4xl leading-[1.02] tracking-[-0.045em] sm:text-5xl">
              Five syntaxes. One compiler contract.
            </h2>
          </div>
          <p className="max-w-2xl text-lg leading-8 text-[#aeb9b0] lg:justify-self-end">
            Pick CSS, SCSS, Sass, Less, or Stylus and inspect real source bytes, the exact pinned provider, and the compact CSS that survives ZigCSS validation.
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

          <div id="format-example-panel" role="tabpanel" className="grid min-w-0 grid-cols-1 lg:grid-cols-2">
            <div className="min-w-0 border-b border-[#3b493f] p-5 sm:p-7 lg:border-b-0 lg:border-r">
              <div className="flex items-center justify-between gap-4">
                <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#89958c]">Input {selected.extension}</p>
                <span className="border border-[#46544a] px-2 py-1 font-mono text-[11px] text-[#aeb9b0]">{selected.label}</span>
              </div>
              <pre className="mt-5 min-h-64 overflow-x-auto bg-[#0a110d] p-5 text-sm leading-6 text-[#e0e6e1]"><code data-language="text">{selected.input}</code></pre>
            </div>

            <div className="min-w-0 p-5 sm:p-7" aria-live="polite">
              <div className="flex flex-wrap items-center justify-between gap-4">
                <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#89958c]">ZigCSS result</p>
                <span className="inline-flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.12em] text-[#b7f34a]">
                  <CheckCircle2 className="size-4" />
                  CSS emitted
                </span>
              </div>

              <pre className="mt-5 min-h-64 overflow-x-auto bg-[#0a110d] p-5 text-sm leading-6 text-[#d4ff86]"><code data-language="text">{selected.output}</code></pre>

              <div className="mt-5 grid gap-3 border-t border-[#3b493f] pt-5 text-sm leading-6 text-[#9eaba1] sm:grid-cols-[auto_1fr]">
                <span className="font-mono text-xs uppercase tracking-[0.14em] text-[#d4ff86]">{selected.provider}</span>
                <div>
                  <code className="block overflow-x-auto whitespace-nowrap font-mono text-xs text-[#cbd4cc]">{selected.pipeline}</code>
                  <p className="mt-2">{selected.note}</p>
                </div>
              </div>
            </div>
          </div>
        </div>

        <div className="mt-9 flex flex-col gap-4 border-l-2 border-[#b7f34a] pl-5 sm:flex-row sm:items-center sm:justify-between">
          <p className="max-w-3xl text-sm leading-6 text-[#9eaba1]">
            Canonical language support is version-pinned and fail-closed. Arbitrary plugins, custom functions, custom importers, and executable project code remain a separate trust boundary.
          </p>
          <Link to="/docs/guide/format-compatibility" className="inline-flex flex-shrink-0 items-center gap-2 font-semibold text-[#b7f34a] hover:underline">
            Format policy <ArrowRight className="size-4" />
          </Link>
        </div>
      </div>
    </section>
  );
}
