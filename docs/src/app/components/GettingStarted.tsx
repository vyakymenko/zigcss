import { Link } from "react-router";
import { AlertTriangle, CheckCircle2, Terminal } from "lucide-react";

export function GettingStarted() {
  return (
    <div className="min-h-screen py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-4xl mx-auto">
        <h1 className="text-4xl mb-4">Build the experimental compiler</h1>
        <div className="flex gap-3 p-5 rounded-xl bg-amber-50 border border-amber-200 text-amber-950 mb-10">
          <AlertTriangle className="size-6 flex-shrink-0" />
          <p>
            ZigCSS 0.3 is a recovery prototype with known semantic defects. Build it for contribution and evaluation only.
          </p>
        </div>

        <section className="bg-white rounded-xl p-8 shadow-sm border border-slate-200 mb-8">
          <div className="flex items-center gap-3 mb-5">
            <Terminal className="size-7 text-indigo-700" />
            <h2 className="text-3xl">Source build</h2>
          </div>
          <p className="text-slate-700 mb-5">Use Zig 0.15.2 and run:</p>
          <pre className="bg-slate-900 text-slate-100 rounded-lg p-5 overflow-x-auto"><code data-language="bash">{`git clone https://github.com/vyakymenko/zigcss.git
cd zigcss
zig build
zig build test --summary all`}</code></pre>
          <p className="text-slate-600 mt-4">
            The executable is written to <code className="px-1.5 py-0.5 bg-slate-100 rounded">zig-out/bin/zigcss</code>.
          </p>
        </section>

        <section className="bg-white rounded-xl p-8 shadow-sm border border-slate-200 mb-8">
          <h2 className="text-3xl mb-5">Characterization run</h2>
          <p className="text-slate-700 mb-4">Start with deliberately simple CSS:</p>
          <pre className="bg-slate-900 text-slate-100 rounded-lg p-5 overflow-x-auto mb-4"><code data-language="css">{`.notice {
  color: red;
}`}</code></pre>
          <pre className="bg-slate-900 text-green-300 rounded-lg p-5 overflow-x-auto"><code data-language="bash">zig-out/bin/zigcss input.css -o output.css</code></pre>
          <p className="text-slate-600 mt-4">
            A warning on standard error identifies the build as experimental. Successful output is not yet a standards guarantee.
          </p>
        </section>

        <section className="bg-white rounded-xl p-8 shadow-sm border border-slate-200">
          <h2 className="text-3xl mb-5">Before reporting a result</h2>
          <ul className="space-y-3 text-slate-700">
            <li className="flex gap-3"><CheckCircle2 className="size-5 text-emerald-700 mt-0.5" />Run the Debug and ReleaseSafe test suites.</li>
            <li className="flex gap-3"><CheckCircle2 className="size-5 text-emerald-700 mt-0.5" />Compare input and output semantics, not only byte size or elapsed time.</li>
            <li className="flex gap-3"><CheckCircle2 className="size-5 text-emerald-700 mt-0.5" />Include a minimal reproduction for any parser or emitter defect.</li>
          </ul>
          <Link to="/docs/guide/status" className="inline-block mt-7 text-indigo-700 hover:underline">
            Review the current status and known limitations →
          </Link>
        </section>
      </div>
    </div>
  );
}
