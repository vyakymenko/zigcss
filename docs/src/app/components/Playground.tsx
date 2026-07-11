import { Link } from "react-router";
import { CircleOff } from "lucide-react";

export function Playground() {
  return (
    <div className="min-h-[70vh] px-4 py-20 flex items-center justify-center">
      <section className="max-w-2xl w-full bg-white border border-slate-200 rounded-2xl p-10 text-center shadow-sm">
        <CircleOff className="size-14 text-slate-500 mx-auto mb-5" />
        <h1 className="text-4xl mb-4">Playground unavailable</h1>
        <p className="text-lg text-slate-600 mb-4">
          The public compile API is disabled while request limits, process isolation, and compiler correctness are rebuilt.
        </p>
        <p className="text-slate-600 mb-8">
          This page will return only after the service has bounded resource tests and the new standards-oriented parser is ready.
        </p>
        <Link to="/docs/guide/status" className="inline-block px-6 py-3 bg-indigo-700 text-white rounded-lg">
          Read current status
        </Link>
      </section>
    </div>
  );
}
