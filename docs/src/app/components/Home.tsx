import { Link } from "react-router";
import { AlertTriangle, ArrowRight, FlaskConical, LockKeyhole, Terminal } from "lucide-react";

export function Home() {
  return (
    <div className="w-full">
      <section className="relative overflow-hidden">
        <div className="absolute inset-0 bg-gradient-to-br from-amber-100 via-white to-indigo-100 opacity-80" />
        <div className="relative max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 py-24 md:py-32">
          <div className="max-w-4xl">
            <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-amber-100 text-amber-900 mb-6">
              <AlertTriangle className="size-4" />
              <span className="text-sm font-semibold">Experimental release candidate</span>
            </div>

            <h1 className="text-5xl md:text-7xl mb-6 bg-gradient-to-r from-indigo-700 to-purple-700 bg-clip-text text-transparent">
              ZigCSS
            </h1>

            <p className="text-xl md:text-2xl text-slate-700 mb-4 leading-relaxed">
              A CSS compiler prototype being rebuilt around security, standards parsing, and semantic preservation.
            </p>
            <p className="text-lg text-slate-600 mb-10">
              The 0.4.0-rc.2 recovery compiler has a tested grammar boundary, but browser semantics and later product gates remain incomplete. It is for development and evaluation, not production use.
            </p>

            <div className="flex flex-col sm:flex-row gap-4">
              <Link
                to="/docs/guide/status"
                className="px-7 py-3.5 bg-indigo-700 text-white rounded-lg hover:bg-indigo-800 transition-colors flex items-center justify-center gap-2"
              >
                Read current status
                <ArrowRight className="size-5" />
              </Link>
              <Link
                to="/getting-started"
                className="px-7 py-3.5 bg-white text-slate-900 rounded-lg border border-slate-300 hover:border-indigo-400 transition-colors flex items-center justify-center gap-2"
              >
                Build from source
                <Terminal className="size-5" />
              </Link>
            </div>
          </div>
        </div>
      </section>

      <section className="py-20 bg-white">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
          <h2 className="text-3xl md:text-4xl mb-10">Recovery priorities</h2>
          <div className="grid md:grid-cols-3 gap-6">
            <article className="p-7 rounded-xl border border-slate-200 bg-slate-50">
              <LockKeyhole className="size-8 text-indigo-700 mb-4" />
              <h3 className="text-xl mb-2">Contain unsafe surfaces</h3>
              <p className="text-slate-600">
                Destructive output plans and unsafe transforms fail explicitly. The public compiler service remains disabled.
              </p>
            </article>
            <article className="p-7 rounded-xl border border-slate-200 bg-slate-50">
              <FlaskConical className="size-8 text-purple-700 mb-4" />
              <h3 className="text-xl mb-2">Make failures executable</h3>
              <p className="text-slate-600">
                Audit reproductions are committed as regressions so the new tokenizer and parser have concrete contracts.
              </p>
            </article>
            <article className="p-7 rounded-xl border border-slate-200 bg-slate-50">
              <Terminal className="size-8 text-emerald-700 mb-4" />
              <h3 className="text-xl mb-2">Keep claims testable</h3>
              <p className="text-slate-600">
                Current documentation lists only verified boundaries and labels every incomplete compiler surface clearly.
              </p>
            </article>
          </div>
        </div>
      </section>
    </div>
  );
}
