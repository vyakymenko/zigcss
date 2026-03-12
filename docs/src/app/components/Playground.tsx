import { useState } from "react";
import { Play, Copy, Check, RotateCcw } from "lucide-react";

const DEFAULT_CSS_INPUT = `/* CSS Input */
.card {
  background: linear-gradient(135deg, #6366f1, #8b5cf6);
  padding: 32px;
  border-radius: 8px;
  color: white;
}

.card:hover {
  transform: translateY(-4px);
  box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2);
}

.card .title {
  font-size: 24px;
  margin-bottom: 16px;
}

.card .content {
  opacity: 0.9;
  line-height: 1.6;
}

.button-primary {
  background: #6366f1;
  border: 2px solid #4f46e5;
}

.button-primary:hover {
  background: #5558e3;
}`;

const DEFAULT_CSS_OUTPUT = `/* CSS Output */
.card {
  background: linear-gradient(135deg, #6366f1, #8b5cf6);
  padding: 32px;
  border-radius: 8px;
  color: white;
}

.card:hover {
  transform: translateY(-4px);
  box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2);
}

.card .title {
  font-size: 24px;
  margin-bottom: 16px;
}

.card .content {
  opacity: 0.9;
  line-height: 1.6;
}

.button-primary {
  background: #6366f1;
  border: 2px solid #4f46e5;
}

.button-primary:hover {
  background: #5558e3;
}`;

const COMPILE_API = "/api/compile";

export function Playground() {
  const [input, setInput] = useState(DEFAULT_CSS_INPUT);
  const [css, setCss] = useState(DEFAULT_CSS_OUTPUT);
  const [copied, setCopied] = useState(false);
  const [compiling, setCompiling] = useState(false);
  const [compileError, setCompileError] = useState<string | null>(null);
  const [minify, setMinify] = useState(false);

  const handleCompile = async () => {
    setCompileError(null);
    setCompiling(true);
    try {
      const res = await fetch(COMPILE_API, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ input, minify }),
      });
      const data = await res.json();
      if (data.error) {
        setCompileError(data.error);
        return;
      }
      if (typeof data.css === "string") setCss(data.css);
    } catch {
      setCompileError("Compile API unavailable. Run with npm run dev and ensure zigcss is installed.");
    } finally {
      setCompiling(false);
    }
  };

  const handleReset = () => {
    setInput(DEFAULT_CSS_INPUT);
    setCss(DEFAULT_CSS_OUTPUT);
  };

  const handleCopy = async () => {
    await navigator.clipboard.writeText(css);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  return (
    <div className="min-h-screen py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-7xl mx-auto">
        <div className="text-center mb-8">
          <h1 className="text-4xl mb-4">ZigCSS Playground</h1>
          <p className="text-xl text-slate-600">
            Try CSS in your browser. Write code on the left, see the output on the right.
          </p>
          <p className="mt-3 text-sm font-medium text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-4 py-2 inline-block">
            SCSS, SASS, LESS, Stylus — coming soon
          </p>
        </div>

        {/* Options & Action Buttons */}
        <div className="flex flex-wrap items-center justify-center gap-4 mb-6">
          <label className="flex items-center gap-2 cursor-pointer select-none">
            <input
              type="checkbox"
              checked={minify}
              onChange={(e) => setMinify(e.target.checked)}
              className="size-4 rounded border-slate-300 text-indigo-600 focus:ring-indigo-500"
            />
            <span className="text-slate-700">Minify output</span>
          </label>
          <button
            onClick={handleCompile}
            disabled={compiling}
            className="flex items-center gap-2 px-6 py-3 bg-gradient-to-r from-indigo-600 to-purple-600 text-white rounded-lg hover:shadow-lg hover:scale-105 transition-all disabled:opacity-70"
          >
            <Play className="size-5" />
            {compiling ? "Compiling…" : "Compile"}
          </button>
          <button
            onClick={handleReset}
            className="flex items-center gap-2 px-6 py-3 bg-slate-700 text-white rounded-lg hover:bg-slate-600 transition-colors"
          >
            <RotateCcw className="size-5" />
            Reset
          </button>
          <button
            onClick={handleCopy}
            className="flex items-center gap-2 px-6 py-3 bg-white border border-slate-300 text-slate-900 rounded-lg hover:border-indigo-300 hover:shadow-md transition-all"
          >
            {copied ? (
              <>
                <Check className="size-5 text-green-600" />
                Copied!
              </>
            ) : (
              <>
                <Copy className="size-5" />
                Copy CSS
              </>
            )}
          </button>
        </div>

        {/* Editors Grid */}
        <div className="grid lg:grid-cols-2 gap-6">
          {/* CSS Input */}
          <div className="bg-white rounded-xl shadow-lg overflow-hidden border border-slate-200">
            <div className="bg-gradient-to-r from-indigo-600 to-purple-600 px-6 py-3 text-white flex items-center justify-between">
              <span>CSS Input</span>
              <span className="text-sm opacity-80">.css</span>
            </div>
            <div className="p-4">
              <textarea
                value={input}
                onChange={(e) => setInput(e.target.value)}
                className="w-full h-[600px] font-mono text-sm bg-slate-900 text-slate-100 p-4 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 resize-none"
                spellCheck={false}
              />
            </div>
          </div>

          {/* CSS Output */}
          <div className="bg-white rounded-xl shadow-lg overflow-hidden border border-slate-200">
            <div className="bg-gradient-to-r from-green-600 to-emerald-600 px-6 py-3 text-white flex items-center justify-between">
              <span>CSS Output</span>
              <span className="text-sm opacity-80">.css</span>
            </div>
            <div className="p-4">
              <textarea
                value={css}
                readOnly
                className="w-full h-[600px] font-mono text-sm bg-slate-900 text-slate-100 p-4 rounded-lg focus:outline-none resize-none"
                spellCheck={false}
              />
            </div>
          </div>
        </div>

        {compileError && (
          <div className="mt-6 p-4 bg-red-50 border border-red-200 rounded-lg text-red-800 text-sm">
            {compileError}
          </div>
        )}
        <div className="mt-8 bg-indigo-50 border border-indigo-200 rounded-lg p-6">
          <h3 className="text-lg mb-3 text-indigo-900">💡 Playground Tips</h3>
          <ul className="space-y-2 text-slate-700">
            <li>• Plain CSS for now. Full SCSS, SASS, LESS &amp; Stylus support is in progress.</li>
            <li>• Check <strong>Minify output</strong> to get compressed CSS.</li>
            <li>• Compile uses the zigcss CLI. Run <code className="px-2 py-1 bg-white rounded">npm run dev</code> and click Compile.</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
