import { Link } from "react-router";
import { AlertTriangle, ArrowRight, CheckCircle2, Package, Terminal } from "lucide-react";

export function GettingStarted() {
  return (
    <div className="min-h-screen bg-[#f3f0e7] text-[#172019]">
      <section className="border-b border-[#334139] bg-[#101914] text-[#f7f3e8]">
        <div className="mx-auto max-w-5xl px-5 py-16 sm:px-8 md:py-24">
          <p className="font-mono text-xs uppercase tracking-[0.2em] text-[#b7f34a]">Get started</p>
          <h1 className="display-type mt-5 max-w-3xl text-5xl tracking-[-0.05em] sm:text-6xl">Start with any of five stylesheet languages.</h1>
          <p className="mt-6 max-w-2xl text-lg leading-8 text-[#cbd4cc]">
            The source snapshot compiles CSS, SCSS, indented Sass, Less, and Stylus through self-contained native Zig frontends and one strict output boundary.
          </p>
        </div>
      </section>

      <div className="mx-auto max-w-5xl px-5 py-14 sm:px-8 md:py-20">
        <div className="mb-10 flex gap-4 border border-[#d0a43f] bg-[#fff2bf] p-5 text-[#4d3a0e]">
          <AlertTriangle className="mt-0.5 size-5 flex-shrink-0" />
          <p className="leading-7">
            The public npm release candidate is still 0.4.0-rc.3 and CSS-only. The five-language 0.6.0-rc.1 source candidate is selected and locally validated but remains experimental and unpublished pending hosted evidence; evaluate before production.
          </p>
        </div>

        <section className="grid gap-px border border-[#bdb8aa] bg-[#bdb8aa] lg:grid-cols-[0.72fr_1.28fr]">
          <div className="bg-[#e8e4d9] p-7 sm:p-9">
            <Package className="size-7 text-[#476f14]" />
            <h2 className="mt-5 text-3xl font-semibold tracking-[-0.03em]">Install from npm</h2>
            <p className="mt-4 leading-7 text-[#5f675f]">
              This release candidate installs the matching native binary for your OS and architecture. Its npm bytes predate the five-language product surface shown below.
            </p>
          </div>
          <div className="bg-[#101914] p-7 text-[#f7f3e8] sm:p-9">
            <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#b7f34a]">Prerelease channel</p>
            <pre className="mt-4 overflow-x-auto bg-[#080d0a] p-4 text-sm sm:text-base"><code data-language="bash">npm install --save-dev zigcss@next</code></pre>
            <p className="mt-6 font-mono text-xs uppercase tracking-[0.16em] text-[#829087]">Compile published CSS surface</p>
            <pre className="mt-4 overflow-x-auto bg-[#080d0a] p-4 text-sm sm:text-base"><code data-language="bash">npx zigcss input.css -o output.css --minify</code></pre>
          </div>
        </section>

        <section className="mt-10 border-l-4 border-[#7b493f] bg-[#f9f6ed] p-7 sm:p-8">
          <h2 className="text-2xl font-semibold">Five native inputs, one self-contained compiler</h2>
          <p className="mt-4 text-lg font-semibold">CSS, SCSS, indented Sass, Less, and Stylus are admitted in the 0.5 source snapshot.</p>
          <p className="mt-2 leading-7 text-[#5f675f]">
            The native Sass-family, Less, and Stylus frontends evaluate complete stylesheets before recovery-disabled ZigCSS validation returns CSS.
          </p>
          <p className="mt-2 leading-7 text-[#5f675f]">
            Dart Sass 1.101.0, Less 4.6.7, and Stylus 0.64.0 remain development-only reference oracles; they do not run during compilation.
          </p>
          <p className="mt-3 leading-7 text-[#5f675f]">
            The default contract does not enable arbitrary plugins, custom functions, custom importers, hooks, JavaScript, or executable project code. Local imports require explicit confined roots.
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
          <p className="mt-2 text-[#5f675f]">Stylesheet compilation itself requires no Node.js, provider process, network service, or runtime download.</p>
          <pre className="mt-5 overflow-x-auto border border-[#334139] bg-[#101914] p-5 text-sm leading-7 text-[#e5ece6]"><code data-language="bash">{`git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all
zig-out/bin/zigcss --syntax scss input.scss -o output.css --minify`}</code></pre>
          <p className="mt-4 text-[#5f675f]">
            The <code className="bg-[#e2ded2] px-1.5 py-0.5 font-mono text-sm">zig-out/bin/zigcss</code> executable owns all five languages. The package JavaScript wrapper only locates and invokes that binary; it does not host language semantics.
          </p>
        </section>

        <section className="mt-14 grid gap-7 lg:grid-cols-2">
          <div className="border border-[#bdb8aa] bg-[#f9f6ed] p-7">
            <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#476f14]">input.scss</p>
            <pre className="mt-5 overflow-x-auto text-sm leading-7"><code data-language="scss">{`$accent: #b7f34a;
.notice {
  color: $accent;
}`}</code></pre>
          </div>
          <div className="border border-[#334139] bg-[#101914] p-7 text-[#f7f3e8]">
            <p className="font-mono text-xs uppercase tracking-[0.16em] text-[#b7f34a]">Run the local binary</p>
            <pre className="mt-5 overflow-x-auto text-sm leading-7 text-[#dce5dd]"><code data-language="bash">zig-out/bin/zigcss --syntax scss input.scss -o output.css --minify</code></pre>
            <p className="mt-5 text-sm leading-6 text-[#9daaa0]">
              This direct command exercises the native Sass-family frontend and the same owned validation result used by the other native syntax routes.
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
