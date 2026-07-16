import { Link } from "react-router";
import { AlertTriangle, ArrowRight, CheckCircle2, Package, Terminal } from "lucide-react";

export function GettingStarted() {
  return (
    <div className="min-h-screen bg-[#f3f0e7] text-[#172019]">
      <section className="border-b border-[#334139] bg-[#101914] text-[#f7f3e8]">
        <div className="mx-auto max-w-5xl px-5 py-16 sm:px-8 md:py-24">
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-[#b7f34a]">Get started</p>
          <h1 className="display-type mt-5 max-w-3xl text-5xl tracking-[-0.05em] sm:text-6xl">Start compiling CSS.</h1>
          <p className="mt-6 max-w-2xl text-lg leading-8 text-[#cbd4cc]">
            Install the native CLI through npm, compile one file, and keep the current compatibility boundary visible while you evaluate it.
          </p>
        </div>
      </section>

      <div className="mx-auto max-w-5xl px-5 py-14 sm:px-8 md:py-20">
        <div className="mb-10 flex gap-4 border border-[#d0a43f] bg-[#fff2bf] p-5 text-[#4d3a0e]">
          <AlertTriangle className="mt-0.5 size-5 flex-shrink-0" />
          <p className="leading-7">
            ZigCSS 0.4.0-rc.2 is an experimental release candidate. Evaluate before production and report semantic differences with a minimal reproduction.
          </p>
        </div>

        <section className="grid gap-px border border-[#bdb8aa] bg-[#bdb8aa] lg:grid-cols-[0.72fr_1.28fr]">
          <div className="bg-[#e8e4d9] p-7 sm:p-9">
            <Package className="size-7 text-[#476f14]" />
            <h2 className="mt-5 text-3xl font-semibold tracking-[-0.03em]">Install from npm</h2>
            <p className="mt-4 leading-7 text-[#5f675f]">
              The postinstall step selects the matching signed release binary for your OS and architecture.
            </p>
          </div>
          <div className="bg-[#101914] p-7 text-[#f7f3e8] sm:p-9">
            <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#b7f34a]">Prerelease channel</p>
            <pre className="mt-4 overflow-x-auto bg-[#080d0a] p-4 text-sm sm:text-base"><code data-language="bash">npm install --save-dev zigcss@next</code></pre>
            <p className="mt-6 font-mono text-xs uppercase tracking-[0.16em] text-[#829087]">Compile</p>
            <pre className="mt-4 overflow-x-auto bg-[#080d0a] p-4 text-sm sm:text-base"><code data-language="bash">npx zigcss input.css -o output.css --minify</code></pre>
          </div>
        </section>

        <section className="mt-10 border-l-4 border-[#7b493f] bg-[#f9f6ed] p-7 sm:p-8">
          <h2 className="text-2xl font-semibold">Know the input boundary</h2>
          <p className="mt-4 text-lg font-semibold">Input must be CSS.</p>
          <p className="mt-2 leading-7 text-[#5f675f]">
            SCSS, Sass, and Less are rejected before output because ZigCSS does not ship a preprocessor. CSS Modules are a separate experimental Zig-library subset, not a CLI format.
          </p>
          <Link to="/docs/guide/format-compatibility" className="mt-5 inline-flex items-center gap-2 font-semibold text-[#36570d] hover:underline">
            Read format compatibility <ArrowRight className="size-4" />
          </Link>
        </section>

        <section className="mt-14">
          <div className="flex items-center gap-3">
            <Terminal className="size-7 text-[#476f14]" />
            <h2 className="text-3xl font-semibold tracking-[-0.03em]">Build from source</h2>
          </div>
          <p className="mt-5 text-[#5f675f]">Use Zig 0.15.2 and run:</p>
          <pre className="mt-5 overflow-x-auto border border-[#334139] bg-[#101914] p-5 text-sm leading-7 text-[#e5ece6]"><code data-language="bash">{`git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all`}</code></pre>
          <p className="mt-4 text-[#5f675f]">
            The executable is written to <code className="bg-[#e2ded2] px-1.5 py-0.5 font-mono text-sm">zig-out/bin/zigcss</code>.
          </p>
        </section>

        <section className="mt-14 grid gap-7 lg:grid-cols-2">
          <div className="border border-[#bdb8aa] bg-[#f9f6ed] p-7">
            <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#476f14]">input.css</p>
            <pre className="mt-5 overflow-x-auto text-sm leading-7"><code data-language="css">{`.notice {
  color: red;
}`}</code></pre>
          </div>
          <div className="border border-[#334139] bg-[#101914] p-7 text-[#f7f3e8]">
            <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#b7f34a]">Run the local binary</p>
            <pre className="mt-5 overflow-x-auto text-sm leading-7 text-[#dce5dd]"><code data-language="bash">zig-out/bin/zigcss input.css -o output.css</code></pre>
            <p className="mt-5 text-sm leading-6 text-[#9daaa0]">
              The release candidate warning is written to stderr. A successful result is not a complete standards guarantee.
            </p>
          </div>
        </section>

        <section className="mt-14 border-t border-[#bdb8aa] pt-10">
          <h2 className="text-3xl font-semibold tracking-[-0.03em]">Before reporting a result</h2>
          <ul className="mt-7 grid gap-4 text-[#4f594f] md:grid-cols-3">
            <li className="flex gap-3"><CheckCircle2 className="mt-0.5 size-5 flex-shrink-0 text-[#476f14]" />Run the Debug and ReleaseSafe test suites.</li>
            <li className="flex gap-3"><CheckCircle2 className="mt-0.5 size-5 flex-shrink-0 text-[#476f14]" />Compare semantics, not only bytes or elapsed time.</li>
            <li className="flex gap-3"><CheckCircle2 className="mt-0.5 size-5 flex-shrink-0 text-[#476f14]" />Attach the smallest CSS reproduction you can make.</li>
          </ul>
          <Link to="/docs/guide/status" className="mt-8 inline-flex items-center gap-2 font-semibold text-[#36570d] hover:underline">
            Review the current status and known limitations <ArrowRight className="size-4" />
          </Link>
        </section>
      </div>
    </div>
  );
}
