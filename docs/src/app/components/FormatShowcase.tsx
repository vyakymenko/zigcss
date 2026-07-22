import { useRef, useState, type KeyboardEvent } from "react";
import { Link } from "react-router";
import formatExamples from "../../data/format-examples.json";
import { deterministicDigest, reductionPercent, utf8Bytes } from "../lib/compilerEvidence";

type FormatExample = (typeof formatExamples)[number];

function reductionLabel(example: FormatExample) {
  const reduction = reductionPercent(example.input, example.output);
  return reduction >= 0 ? `${reduction}% smaller` : `${Math.abs(reduction)}% larger`;
}

export function FormatShowcase() {
  const [selectedId, setSelectedId] = useState<FormatExample["id"]>("css");
  const tabs = useRef<Array<HTMLButtonElement | null>>([]);
  const selected = formatExamples.find(example => example.id === selectedId) ?? formatExamples[0];
  const selectedIndex = formatExamples.findIndex(example => example.id === selected.id);

  const selectTab = (index: number) => {
    const nextIndex = (index + formatExamples.length) % formatExamples.length;
    setSelectedId(formatExamples[nextIndex].id);
    tabs.current[nextIndex]?.focus();
  };

  const handleTabKey = (event: KeyboardEvent<HTMLButtonElement>) => {
    if (event.key === "ArrowRight") selectTab(selectedIndex + 1);
    else if (event.key === "ArrowLeft") selectTab(selectedIndex - 1);
    else if (event.key === "Home") selectTab(0);
    else if (event.key === "End") selectTab(formatExamples.length - 1);
    else return;
    event.preventDefault();
  };

  return (
    <section id="formats" className="lab-section gate-section site-grid bg-[#0b110d] text-[#eef5ec]" aria-labelledby="format-lab-title">
      <div className="mx-auto max-w-[96rem] px-5 py-28 sm:px-8 md:py-40 lg:px-12">
        <p className="gate-label">── GATE 06 · RECORDED COMPILER LAB ──</p>
        <div className="mt-7 grid gap-8 lg:grid-cols-[1.05fr_0.95fr] lg:items-end">
          <h2 id="format-lab-title" className="display-type max-w-5xl text-[clamp(3.2rem,7.2vw,7rem)] leading-[0.84] tracking-[-0.07em]">
            Five syntaxes. <span className="text-[#b7f34a]">One CSS destination.</span>
          </h2>
          <p className="max-w-2xl font-mono text-sm leading-7 text-[#8d9a8b] lg:justify-self-end">
            Recorded compiler fixtures. Not a browser simulation. Select an input and inspect the exact provider, bytes, digest, and admitted CSS output.
          </p>
        </div>

        <div className="lab-instrument mt-14 border border-[#b7f34a]/20 bg-[#101914] shadow-[0_24px_80px_rgba(0,0,0,0.42)]">
          <div className="flex overflow-x-auto border-b border-[#b7f34a]/20 bg-[#0c130e]" role="tablist" aria-label="Stylesheet input formats">
            {formatExamples.map((example, index) => (
              <button
                key={example.id}
                ref={element => { tabs.current[index] = element; }}
                id={`format-tab-${example.id}`}
                type="button"
                role="tab"
                aria-label={example.label}
                aria-selected={selected.id === example.id}
                aria-controls="format-example-panel"
                tabIndex={selected.id === example.id ? 0 : -1}
                onClick={() => setSelectedId(example.id)}
                onKeyDown={handleTabKey}
                className={`lab-tab min-w-28 flex-1 border-r border-[#b7f34a]/10 px-5 py-5 text-left font-mono text-xs uppercase tracking-[0.16em] transition ${
                  selected.id === example.id
                    ? "bg-[#b7f34a] text-[#0b110d]"
                    : "text-[#7f8d7d] hover:bg-[#152019] hover:text-[#eef5ec]"
                }`}
              >
                <span className="block text-[10px] opacity-60">0{index + 1}</span>
                <span className="mt-1 block">{example.label}</span>
              </button>
            ))}
          </div>

          <div
            id="format-example-panel"
            role="tabpanel"
            aria-labelledby={`format-tab-${selected.id}`}
            className="grid min-w-0 grid-cols-1 xl:grid-cols-2"
          >
            <div className="min-w-0 border-b border-[#b7f34a]/20 p-5 sm:p-8 xl:border-b-0 xl:border-r">
              <div className="flex flex-wrap items-center justify-between gap-4">
                <p className="terminal-label">input {selected.extension}</p>
                <span className="terminal-chip">{selected.provider}</span>
              </div>
              <pre className="lab-code mt-6 min-h-72 overflow-x-auto border border-[#b7f34a]/10 bg-[#080d0a] p-5 text-sm leading-7 text-[#e5ece3]"><code data-language="text">{selected.input}</code><span className="block-caret ml-1 inline-block" aria-hidden="true" /></pre>
            </div>

            <div key={selected.id} className="compile-output relative min-w-0 overflow-hidden p-5 sm:p-8" aria-live="polite">
              <div className="compile-scanline" aria-hidden="true" />
              <div className="flex flex-wrap items-center justify-between gap-4">
                <p className="terminal-label">output .css</p>
                <span className="terminal-chip text-[#b7f34a]">recorded compiler output · deterministic</span>
              </div>
              <pre className="lab-code mt-6 min-h-72 overflow-x-auto border border-[#b7f34a]/10 bg-[#080d0a] p-5 text-sm leading-7 text-[#dfffa0]"><code data-language="text">{selected.output}</code></pre>
            </div>
          </div>

          <div className="grid border-t border-[#b7f34a]/20 bg-[#0c130e] sm:grid-cols-2 xl:grid-cols-4">
            <div className="evidence-cell">
              <span>input</span>
              <strong>{utf8Bytes(selected.input)} bytes</strong>
            </div>
            <div className="evidence-cell">
              <span>output</span>
              <strong>{utf8Bytes(selected.output)} bytes</strong>
            </div>
            <div className="evidence-cell">
              <span>change</span>
              <strong>{reductionLabel(selected)}</strong>
            </div>
            <div className="evidence-cell">
              <span>digest</span>
              <strong>{deterministicDigest(selected.output)}</strong>
            </div>
          </div>

          <div className="grid gap-4 border-t border-[#b7f34a]/20 p-5 font-mono text-xs leading-6 text-[#829080] sm:p-8 lg:grid-cols-[auto_1fr]">
            <span className="text-[#b7f34a]">pipeline</span>
            <div>
              <code className="block overflow-x-auto whitespace-nowrap text-[#cbd5c9]">{selected.pipeline}</code>
              <p className="mt-2">{selected.note}</p>
            </div>
          </div>
        </div>

        <div className="mt-8 flex flex-col gap-4 border-l border-[#b7f34a] pl-5 font-mono text-xs leading-6 text-[#81907f] sm:flex-row sm:items-center sm:justify-between">
          <p className="max-w-4xl">
            CSS is native. Canonical preprocessor behavior remains version-pinned and fail-closed while SCSS, Sass, Less, and Stylus earn native graduation.
          </p>
          <Link to="/docs/guide/format-compatibility" className="terminal-link flex-shrink-0 text-[#b7f34a]">
            format policy →
          </Link>
        </div>
      </div>
    </section>
  );
}
