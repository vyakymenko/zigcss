import { Link } from "react-router";
import {
  ArrowRight,
  Braces,
  CheckCircle2,
  CircleOff,
  Layers3,
  ShieldCheck,
  Terminal,
} from "lucide-react";

const languageRows = [
  {
    language: "CSS",
    status: "Experimental",
    detail: "Matrix-tested CLI input with an explicit compatibility boundary.",
    available: true,
  },
  {
    language: "CSS Modules",
    status: "Library subset",
    detail: "Opt-in Zig API surface; not available through the CLI or LSP.",
    available: true,
  },
  {
    language: "SCSS / Sass",
    status: "Not supported",
    detail: "No preprocessor adapter. These extensions fail before output.",
    available: false,
  },
  {
    language: "Less",
    status: "Not supported",
    detail: "No preprocessor adapter. These extensions fail before output.",
    available: false,
  },
] as const;

export function Home() {
  return (
    <div className="w-full bg-[#f3f0e7] text-[#172019]">
      <section className="site-grid relative overflow-hidden bg-[#101914] text-[#f7f3e8]">
        <div className="relative mx-auto grid max-w-7xl gap-14 px-5 py-20 sm:px-8 md:py-28 lg:grid-cols-[1.08fr_0.92fr] lg:items-center lg:px-10">
          <div>
            <div className="mb-7 inline-flex items-center gap-2 border border-[#b7f34a]/40 bg-[#b7f34a]/10 px-3 py-1.5 font-mono text-xs uppercase tracking-[0.18em] text-[#ccff73]">
              <span className="size-1.5 rounded-full bg-[#b7f34a]" />
              0.4.0-rc.3 · experimental
            </div>

            <h1 className="display-type max-w-3xl text-5xl leading-[0.95] tracking-[-0.055em] sm:text-6xl md:text-7xl">
              Compile CSS with Zig.
            </h1>
            <p className="mt-7 max-w-2xl text-lg leading-8 text-[#cbd4cc] md:text-xl">
              A native compiler and Zig library built around deterministic output, semantic preservation, and boundaries you can inspect.
            </p>
            <p className="mt-4 max-w-2xl text-sm leading-6 text-[#97a59b]">
              This is a release candidate with matrix-tested CSS coverage. Evaluate before production; it does not claim complete browser or language compatibility.
            </p>

            <div className="mt-9 flex flex-col gap-3 sm:flex-row">
              <Link
                to="/getting-started"
                className="inline-flex items-center justify-center gap-2 bg-[#b7f34a] px-6 py-3.5 font-semibold text-[#101914] transition hover:bg-[#ceff77]"
              >
                Get started
                <ArrowRight className="size-4" />
              </Link>
              <Link
                to="/features"
                className="inline-flex items-center justify-center gap-2 border border-[#526158] px-6 py-3.5 font-semibold text-[#f7f3e8] transition hover:border-[#b7f34a] hover:text-[#b7f34a]"
              >
                Explore CSS support
              </Link>
            </div>
          </div>

          <div className="border border-[#344139] bg-[#16221b] shadow-[16px_16px_0_0_#0a110d]">
            <div className="flex items-center justify-between border-b border-[#344139] px-5 py-3 font-mono text-xs text-[#92a096]">
              <span>terminal</span>
              <span>npm · native binary</span>
            </div>
            <div className="p-5 sm:p-7">
              <p className="mb-3 font-mono text-xs uppercase tracking-[0.16em] text-[#b7f34a]">Install the prerelease</p>
              <code className="block overflow-x-auto whitespace-nowrap bg-[#0b120e] px-4 py-4 font-mono text-sm text-[#f7f3e8] sm:text-base">
                <span className="text-[#708078]">$ </span>npm install --save-dev zigcss@next
              </code>

              <div className="mt-6 grid gap-px bg-[#344139] sm:grid-cols-2">
                <div className="bg-[#101914] p-4">
                  <p className="font-mono text-xs text-[#708078]">input.css</p>
                  <pre className="mt-3 overflow-x-auto text-sm leading-6 text-[#d9e0da]"><code data-language="css">{`.notice {
  color: red;
}`}</code></pre>
                </div>
                <div className="bg-[#101914] p-4">
                  <p className="font-mono text-xs text-[#708078]">output.css</p>
                  <pre className="mt-3 overflow-x-auto text-sm leading-6 text-[#ccff73]"><code data-language="css">{`.notice{color:red}`}</code></pre>
                </div>
              </div>
              <p className="mt-5 font-mono text-xs text-[#92a096]">
                npx zigcss input.css -o output.css --minify
              </p>
            </div>
          </div>
        </div>
      </section>

      <section className="border-b border-[#c9c5b9] bg-[#e8e4d9]">
        <div className="mx-auto grid max-w-7xl divide-y divide-[#c9c5b9] px-5 sm:px-8 lg:grid-cols-3 lg:divide-x lg:divide-y-0 lg:px-10">
          <article className="py-10 lg:pr-9">
            <ShieldCheck className="size-7 text-[#476f14]" />
            <h2 className="mt-5 text-xl font-semibold">Semantics before speed</h2>
            <p className="mt-3 leading-7 text-[#586159]">
              Transform classes stay disabled until fixtures, independent parsing, and idempotence gates make them safe to expose.
            </p>
          </article>
          <article className="py-10 lg:px-9">
            <Layers3 className="size-7 text-[#476f14]" />
            <h2 className="mt-5 text-xl font-semibold">One compiler path</h2>
            <p className="mt-3 leading-7 text-[#586159]">
              The CLI, Zig API, build helper, profiling, and editor tooling share the owned compile result instead of parallel parsers.
            </p>
          </article>
          <article className="py-10 lg:pl-9">
            <Terminal className="size-7 text-[#476f14]" />
            <h2 className="mt-5 text-xl font-semibold">Native delivery</h2>
            <p className="mt-3 leading-7 text-[#586159]">
              Five architecture-matched release targets are smoke-tested before signed archives can be published.
            </p>
          </article>
        </div>
      </section>

      <section className="mx-auto max-w-7xl px-5 py-20 sm:px-8 md:py-28 lg:px-10">
        <div className="grid gap-12 lg:grid-cols-[0.72fr_1.28fr]">
          <div>
            <p className="font-mono text-xs uppercase tracking-[0.2em] text-[#476f14]">Language boundary</p>
            <h2 className="display-type mt-4 text-4xl tracking-[-0.04em] sm:text-5xl">CSS in. CSS out.</h2>
            <p className="mt-6 max-w-lg text-lg leading-8 text-[#586159]">
              ZigCSS is not a universal stylesheet front end. The stable CLI accepts CSS only, and even that support remains explicitly experimental.
            </p>
            <Link to="/docs/guide/format-compatibility" className="mt-7 inline-flex items-center gap-2 font-semibold text-[#36570d] hover:underline">
              Read the format policy <ArrowRight className="size-4" />
            </Link>
          </div>

          <div className="border border-[#bdb8aa] bg-[#f9f6ed]">
            {languageRows.map((row, index) => (
              <div
                key={row.language}
                className={`grid gap-3 p-5 sm:grid-cols-[0.55fr_0.55fr_1.4fr] sm:items-center sm:p-6 ${index !== 0 ? "border-t border-[#d6d1c5]" : ""}`}
              >
                <p className="font-semibold">{row.language}</p>
                <p className={`inline-flex items-center gap-2 text-sm font-semibold ${row.available ? "text-[#476f14]" : "text-[#7b493f]"}`}>
                  {row.available ? <CheckCircle2 className="size-4" /> : <CircleOff className="size-4" />}
                  {row.status}
                </p>
                <p className="text-sm leading-6 text-[#626a62]">{row.detail}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="bg-[#b7f34a] text-[#101914]">
        <div className="mx-auto flex max-w-7xl flex-col gap-8 px-5 py-14 sm:px-8 md:flex-row md:items-center md:justify-between lg:px-10">
          <div>
            <Braces className="size-7" />
            <h2 className="display-type mt-4 text-3xl tracking-[-0.035em] sm:text-4xl">Inspect the contract, then try the compiler.</h2>
          </div>
          <div className="flex flex-col gap-3 sm:flex-row">
            <Link to="/docs/guide/status" className="border border-[#101914] px-5 py-3 text-center font-semibold hover:bg-[#101914] hover:text-[#b7f34a]">
              Current status
            </Link>
            <Link to="/getting-started" className="bg-[#101914] px-5 py-3 text-center font-semibold text-[#f7f3e8] hover:bg-[#263229]">
              Install ZigCSS
            </Link>
          </div>
        </div>
      </section>
    </div>
  );
}
