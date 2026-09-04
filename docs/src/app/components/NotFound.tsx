import { Link } from "react-router";

export function NotFound() {
  return (
    <section className="site-grid flex min-h-[calc(100svh-4rem)] items-center bg-[#0b110d] px-5 py-20 text-[#eef5ec] sm:px-8" aria-labelledby="not-found-title">
      <div className="mx-auto w-full max-w-4xl border border-[#b7f34a]/20 bg-[#080d0a] font-mono shadow-[16px_16px_0_rgba(183,243,74,0.06)]">
        <div className="flex items-center justify-between border-b border-[#b7f34a]/20 px-5 py-4 text-[10px] uppercase tracking-[0.16em] text-[#879685]">
          <span>zigcss router</span>
          <span className="text-[#b7f34a]">exit 2</span>
        </div>
        <div className="p-6 sm:p-10">
          <p className="text-xs uppercase tracking-[0.16em] text-[#879685]">404 · invalid route</p>
          <h1 id="not-found-title" className="mt-7 text-2xl leading-9 text-[#b7f34a] sm:text-4xl">error: route not found — exit 2</h1>
          <p className="mt-6 max-w-2xl text-sm leading-7 text-[#8b9989]">The requested path is outside the admitted route graph. No partial page was emitted.</p>
          <div className="mt-10 flex flex-wrap gap-3">
            <Link to="/" className="scan-button bg-[#b7f34a] px-5 py-3 text-xs font-semibold uppercase tracking-[0.12em] text-[#0b110d]">Go home</Link>
            <button type="button" onClick={() => window.history.back()} className="border border-[#b7f34a]/25 px-5 py-3 text-xs uppercase tracking-[0.12em] text-[#a8b4a6] hover:border-[#b7f34a]/60 hover:text-[#b7f34a]">Go back</button>
          </div>
        </div>
      </div>
    </section>
  );
}
