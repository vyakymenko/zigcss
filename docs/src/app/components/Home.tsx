import { useRef, useState, type KeyboardEvent } from "react";
import { Link } from "react-router";
import { BootSequence } from "./BootSequence";
import { Convergence } from "./Convergence";
import { FormatShowcase } from "./FormatShowcase";
import { deterministicDigest } from "../lib/compilerEvidence";

const installCommand = "npm install --save-dev zigcss@next";
const deterministicFixture = ":root{--accent:#b7f34a}.button{color:#101914;background:var(--accent)}";

const deploymentModes = [
  {
    id: "npm",
    label: "npm",
    code: `${installCommand}\nnpx zigcss input.css -o output.css --minify`,
    note: "Published next is 0.4.0-rc.3 and exposes the earlier CSS-only surface.",
  },
  {
    id: "source",
    label: "from source",
    code: "zig build\nzig-out/bin/zigcss --syntax scss input.scss -o output.css --minify",
    note: "The native five-language 0.6.0-rc.2 candidate is release-ready and unpublished; no provider runtime is used.",
  },
  {
    id: "zig",
    label: "Zig API",
    code: "const zigcss = @import(\"zigcss\");\nconst result = try zigcss.compile(allocator, path, css, options);\n// helpers.addCssCompile wires declared build inputs",
    note: "Built with Zig 0.15.2. The owned result carries CSS, diagnostics, dependencies, maps, and profile data.",
  },
] as const;

function CopyInstallCommand() {
  const [copyState, setCopyState] = useState<"idle" | "copied" | "unavailable">("idle");

  const copy = async () => {
    try {
      if (!navigator.clipboard) throw new Error("clipboard unavailable");
      await navigator.clipboard.writeText(installCommand);
      setCopyState("copied");
      window.setTimeout(() => setCopyState("idle"), 1800);
    } catch {
      setCopyState("unavailable");
    }
  };

  return (
    <button
      type="button"
      onClick={copy}
      className="install-command scan-button group w-full max-w-3xl border border-[#b7f34a]/55 bg-[#b7f34a] px-5 py-5 text-left text-[#0b110d] shadow-[8px_8px_0_rgba(183,243,74,0.16)] sm:px-7"
      aria-label={`Copy install command: ${installCommand}`}
    >
      <span className="relative z-10 flex flex-col gap-3 font-mono text-xs sm:flex-row sm:items-center sm:justify-between sm:text-sm">
        <span><span aria-hidden="true">$ </span>{installCommand}</span>
        <span className="uppercase tracking-[0.16em]">
          {copyState === "copied" ? "copied" : copyState === "unavailable" ? "select command" : "copy"}
        </span>
      </span>
    </button>
  );
}

function Manifesto() {
  const digest = deterministicDigest(deterministicFixture);

  return (
    <section id="manifesto" className="manifesto bg-[#0b110d] text-[#eef5ec]" aria-label="Compiler manifesto">
      <article className="manifesto-panel gate-section">
        <div className="manifesto-inner">
          <p className="gate-label">── GATE 02 · FAIL-CLOSED SECURITY ──</p>
          <h2 className="manifesto-statement">Your CSS toolchain should not be able to <span>phone home.</span></h2>
          <p className="manifesto-detail">Local imports stay root-confined. Executable extension points stay closed unless the contract explicitly admits them.</p>
          <div className="terminal-ledger" aria-label="Default security policy">
            <p><span>NETWORK</span><strong>DENIED</strong></p>
            <p><span>PLUGINS</span><strong>DENIED</strong></p>
            <p><span>PROJECT CODE</span><strong>DENIED</strong></p>
            <p><span>IMPORTS</span><strong>ROOT-CONFINED</strong></p>
          </div>
        </div>
      </article>

      <article className="manifesto-panel gate-section">
        <div className="manifesto-inner">
          <p className="gate-label">── GATE 03 · DETERMINISM ──</p>
          <h2 className="manifesto-statement">Same input. Same bytes. <span>Every machine. Every time.</span></h2>
          <p className="manifesto-detail">Executable gates repeat work across parallel workers, batch order, and watch invalidation.</p>
          <div className="hash-terminal" aria-label="Repeated deterministic digest">
            {[1, 2, 3].map(run => <p key={run}>run {run} <span>→</span> <strong>{digest}</strong></p>)}
            <p className="mt-4 border-t border-[#b7f34a]/20 pt-4 text-[#b7f34a]">run 1 = run 2 = run 3</p>
          </div>
        </div>
      </article>

      <article className="manifesto-panel gate-section">
        <div className="manifesto-inner">
          <p className="gate-label">── GATE 04 · ATOMIC OUTPUT ──</p>
          <h2 className="manifesto-statement">All output. <span>Or no output.</span></h2>
          <p className="manifesto-detail">A failed compilation returns normalized diagnostics and never attaches partial CSS.</p>
          <div className="failure-terminal" aria-label="Failed compile with zero CSS output">
            <p><span>error[parse]</span> expected declaration</p>
            <p>css bytes <strong>0</strong></p>
            <p>output file <strong>not written</strong></p>
            <p>exit <strong>1</strong></p>
          </div>
        </div>
      </article>

      <article className="manifesto-panel gate-section">
        <div className="manifesto-inner">
          <p className="gate-label">── GATE 05 · ONE COMPILER PATH ──</p>
          <h2 className="manifesto-statement">One path. <span>No parser drift.</span></h2>
          <p className="manifesto-detail">CLI, the thin JavaScript wrapper, Zig API, build helper, profiling, and editor tooling consume the same owned compile result.</p>
          <div className="path-map" aria-label="Compiler consumers converging on one owned result">
            {['CLI', 'JS WRAPPER', 'ZIG API', 'BUILD', 'PROFILE', 'EDITOR'].map(label => <span key={label}>{label}</span>)}
            <strong>OWNED COMPILE RESULT</strong>
          </div>
        </div>
      </article>
    </section>
  );
}

function BenchmarkLock() {
  return (
    <section id="benchmarks" className="benchmark-lock border-y border-[#b7f34a]/15 bg-[#101914] text-[#eef5ec]" aria-labelledby="benchmark-title">
      <div className="mx-auto grid max-w-[96rem] gap-10 px-5 py-20 sm:px-8 md:py-28 lg:grid-cols-[1.15fr_0.85fr] lg:px-12">
        <div>
          <p className="gate-label">EVIDENCE LOCK · PERFORMANCE</p>
          <h2 id="benchmark-title" className="display-type mt-5 max-w-4xl text-[clamp(2.8rem,5.8vw,6rem)] leading-[0.88] tracking-[-0.065em]">
            Native is the architecture. <span className="text-[#b7f34a]">Evidence decides the ranking.</span>
          </h2>
        </div>
        <div className="self-end border-l border-[#b7f34a] pl-6 font-mono text-sm leading-7 text-[#91a08f]">
          <p>Controlled benchmark pipeline required.</p>
          <p>Comparative ranking locked.</p>
          <p>Timing multiplier locked.</p>
          <p>Published claim locked.</p>
          <p className="mt-5 text-[#eef5ec]">Comparative rankings remain unpublished until the controlled pipeline lands.</p>
          <a className="terminal-link mt-5 inline-block text-[#b7f34a]" href="https://github.com/vyakymenko/zigcss/blob/main/BENCHMARK_REPORT.md" target="_blank" rel="noopener noreferrer">
            read benchmark contract →
          </a>
        </div>
      </div>
    </section>
  );
}

function Endgame() {
  return (
    <section id="endgame" className="endgame-section gate-section relative overflow-hidden bg-[#0b110d] text-[#eef5ec]" aria-labelledby="endgame-title">
      <div className="perspective-horizon" aria-hidden="true" />
      <div className="relative mx-auto max-w-[96rem] px-5 py-28 sm:px-8 md:py-44 lg:px-12">
        <div className="flex flex-wrap items-center justify-between gap-5">
          <p className="gate-label">── GATE 07 · ADR-013 ──</p>
          <span className="target-chip">NATIVE SNAPSHOT · RELEASE NOT SHIPPED</span>
        </div>
        <h2 id="endgame-title" className="display-type mt-10 max-w-6xl text-[clamp(3.8rem,9vw,9rem)] leading-[0.8] tracking-[-0.08em]">
          The providers are <span className="text-[#b7f34a]">oracles.</span>
        </h2>
        <p className="mt-10 max-w-3xl font-mono text-sm leading-7 text-[#8d9a8b] sm:text-base">
          All five source inputs run through self-contained native Zig frontends. One self-contained compiler. Zero production package dependencies. No provider process. No runtime download.
        </p>

        <div className="endgame-corridor mt-16 grid gap-3 lg:grid-cols-[1fr_auto_1fr_auto_1fr] lg:items-stretch">
          <article>
            <span>REFERENCE</span>
            <strong>DEVELOPMENT ORACLES</strong>
            <p>Dart Sass 1.101.0 · Less 4.6.7 · Stylus 0.64.0 · tests only</p>
          </article>
          <div className="corridor-arrow" aria-hidden="true">→</div>
          <article>
            <span>CURRENT SOURCE</span>
            <strong>NATIVE GRADUATED</strong>
            <p>All four preprocessor rows pass the complete pre-tag evidence terminal.</p>
          </article>
          <div className="corridor-arrow" aria-hidden="true">→</div>
          <article className="endgame-target">
            <span>RELEASE GATE</span>
            <strong>RELEASE READY</strong>
            <p>nativeReleaseReady: true · 0.6.0-rc.2 · tag pending</p>
          </article>
        </div>
      </div>
    </section>
  );
}

function Deploy() {
  const [selectedId, setSelectedId] = useState<(typeof deploymentModes)[number]["id"]>("npm");
  const tabs = useRef<Array<HTMLButtonElement | null>>([]);
  const selectedIndex = deploymentModes.findIndex(mode => mode.id === selectedId);
  const selected = deploymentModes[selectedIndex] ?? deploymentModes[0];

  const handleKey = (event: KeyboardEvent<HTMLButtonElement>) => {
    let next = selectedIndex;
    if (event.key === "ArrowRight") next += 1;
    else if (event.key === "ArrowLeft") next -= 1;
    else if (event.key === "Home") next = 0;
    else if (event.key === "End") next = deploymentModes.length - 1;
    else return;
    event.preventDefault();
    next = (next + deploymentModes.length) % deploymentModes.length;
    setSelectedId(deploymentModes[next].id);
    tabs.current[next]?.focus();
  };

  return (
    <section id="deploy" className="deploy-section gate-section bg-[#101914] text-[#eef5ec]" aria-labelledby="deploy-title">
      <div className="mx-auto max-w-[96rem] px-5 py-28 sm:px-8 md:py-40 lg:px-12">
        <p className="gate-label">── GATE 08 · DEPLOY ──</p>
        <div className="mt-7 grid gap-10 lg:grid-cols-[0.9fr_1.1fr] lg:items-end">
          <h2 id="deploy-title" className="display-type text-[clamp(3.5rem,8vw,8rem)] leading-[0.82] tracking-[-0.075em]">Choose your <span className="text-[#b7f34a]">entry point.</span></h2>
          <p className="max-w-2xl font-mono text-sm leading-7 text-[#8d9a8b] lg:justify-self-end">
            Exit 0 on success. Exit 1 on compilation or I/O failure. Exit 2 on invalid usage. The contract does not change with the surface.
          </p>
        </div>

        <div className="mt-14 grid gap-8 xl:grid-cols-[1.25fr_0.75fr]">
          <div className="border border-[#b7f34a]/20 bg-[#0b110d]">
            <div role="tablist" aria-label="ZigCSS deployment methods" className="flex border-b border-[#b7f34a]/20">
              {deploymentModes.map((mode, index) => (
                <button
                  key={mode.id}
                  ref={element => { tabs.current[index] = element; }}
                  id={`deploy-tab-${mode.id}`}
                  type="button"
                  role="tab"
                  aria-selected={mode.id === selected.id}
                  aria-controls="deploy-panel"
                  tabIndex={mode.id === selected.id ? 0 : -1}
                  onClick={() => setSelectedId(mode.id)}
                  onKeyDown={handleKey}
                  className={`flex-1 border-r border-[#b7f34a]/10 px-3 py-4 font-mono text-[10px] uppercase tracking-[0.14em] sm:px-5 sm:text-xs ${mode.id === selected.id ? "bg-[#b7f34a] text-[#0b110d]" : "text-[#81907f] hover:text-[#eef5ec]"}`}
                >
                  {mode.label}
                </button>
              ))}
            </div>
            <div id="deploy-panel" role="tabpanel" aria-labelledby={`deploy-tab-${selected.id}`} className="p-5 sm:p-8">
              <pre className="min-h-48 overflow-x-auto font-mono text-xs leading-7 text-[#dfffa0] sm:text-sm"><code data-language="text">{selected.code}</code><span className="block-caret ml-1 inline-block" aria-hidden="true" /></pre>
              <p className="border-t border-[#b7f34a]/15 pt-5 font-mono text-xs leading-6 text-[#7f8d7d]">{selected.note}</p>
            </div>
          </div>

          <aside className="border border-[#b7f34a]/20 p-6 sm:p-8" aria-labelledby="delivery-title">
            <p className="terminal-label">native delivery</p>
            <h3 id="delivery-title" className="mt-4 text-2xl font-semibold">Five architecture-matched targets.</h3>
            <p className="mt-4 font-mono text-xs leading-6 text-[#829080]">Each target is smoke-tested before signed archives.</p>
            <div className="mt-7 flex flex-wrap gap-2">
              {['Linux x64', 'Linux arm64', 'macOS x64', 'macOS arm64', 'Windows x64'].map(target => <span key={target} className="terminal-chip">{target}</span>)}
            </div>
            <p className="mt-9 terminal-label">interfaces</p>
            <p className="mt-3 font-mono text-xs leading-6 text-[#a6b2a4]">CLI · JS wrapper · Zig API · helpers.addCssCompile · CSS LSP</p>
          </aside>
        </div>

        <nav className="mt-12 grid border-y border-[#b7f34a]/15 sm:grid-cols-2 lg:grid-cols-6" aria-label="Project destinations">
          <Link className="deploy-link" to="/docs">Docs</Link>
          <Link className="deploy-link" to="/getting-started">Get started</Link>
          <a className="deploy-link" href="https://github.com/vyakymenko/zigcss" target="_blank" rel="noopener noreferrer">GitHub</a>
          <a className="deploy-link" href="https://www.npmjs.com/package/zigcss" target="_blank" rel="noopener noreferrer">npm</a>
          <a className="deploy-link" href="https://marketplace.visualstudio.com/items?itemName=zigcss.zigcss-language-server" target="_blank" rel="noopener noreferrer">VS Code</a>
          <a className="deploy-link" href="https://github.com/vyakymenko/zigcss/tree/main/neovim-config" target="_blank" rel="noopener noreferrer">Neovim</a>
        </nav>
      </div>
    </section>
  );
}

export function Home() {
  return (
    <div className="terminal-site w-full bg-[#0b110d] text-[#eef5ec]">
      <BootSequence />

      <section className="future-hero relative isolate min-h-[calc(100svh-4rem)] overflow-hidden bg-[#0b110d]" aria-labelledby="hero-title">
        <div className="perspective-horizon" aria-hidden="true" />
        <div className="hero-glow" aria-hidden="true" />
        <div className="relative mx-auto flex min-h-[calc(100svh-4rem)] max-w-[96rem] flex-col justify-center px-5 py-20 sm:px-8 md:py-28 lg:px-12">
          <p className="gate-label">TERMINAL 00 · ZIGCSS SOURCE CANDIDATE</p>
          <div className="experimental-chip mt-7 w-fit">⚠ 0.6.0-rc.2 · EXPERIMENTAL · evaluate before production</div>
          <h1 id="hero-title" className="hero-display display-type mt-9 max-w-[90rem] text-[clamp(4.1rem,12vw,12rem)] leading-[0.74] tracking-[-0.085em]">
            Exact in.<br /><span>Deterministic out.</span><br />Denied by default.
          </h1>
          <div className="mt-10 grid gap-8 lg:grid-cols-[1.15fr_0.85fr] lg:items-end">
            <div>
              <p className="max-w-3xl text-xl leading-8 text-[#cdd6cb] sm:text-2xl">Compile CSS. Keep the meaning.</p>
              <p className="mt-4 max-w-3xl font-mono text-xs leading-6 text-[#81907f] sm:text-sm">
                An experimental self-contained five-language compiler written in Zig. The release-ready 0.6.0-rc.2 candidate remains unpublished pending its immutable tag workflow. Published zigcss@next is 0.4.0-rc.3 with the earlier CSS-only surface. All five source inputs run through self-contained native Zig frontends.
              </p>
            </div>
            <a href="#convergence" className="terminal-link justify-self-start font-mono text-sm uppercase tracking-[0.16em] text-[#b7f34a] lg:justify-self-end">five inputs converge ↓</a>
          </div>
          <div className="mt-10">
            <CopyInstallCommand />
            <a href="#formats" className="terminal-link mt-6 inline-block font-mono text-xs uppercase tracking-[0.18em] text-[#9dab9b]">enter the lab ↓</a>
          </div>
        </div>
      </section>

      <div className="proof-rail border-y border-[#b7f34a]/15 bg-[#101914]" aria-label="Compiler invariants">
        <div className="mx-auto grid max-w-[96rem] sm:grid-cols-3">
          <p><strong>DETERMINISTIC</strong><span>same input → same bytes</span></p>
          <p><strong>ATOMIC</strong><span>failure → zero CSS</span></p>
          <p><strong>FAIL-CLOSED</strong><span>network + code denied</span></p>
        </div>
      </div>

      <Convergence />
      <Manifesto />
      <FormatShowcase />
      <BenchmarkLock />
      <Endgame />
      <Deploy />
    </div>
  );
}
