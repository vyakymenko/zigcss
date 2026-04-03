import { useState } from "react";
import { Play, Copy, Check, RotateCcw } from "lucide-react";

type Format = "css" | "scss";

// ── Default inputs per format ─────────────────────────────────────────────────

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

const DEFAULT_SCSS_INPUT = `// SCSS Input
$primary: #6366f1;
$radius: 8px;

@mixin hover-lift {
  transform: translateY(-4px);
  box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2);
}

.card {
  background: linear-gradient(135deg, $primary, #8b5cf6);
  padding: 32px;
  border-radius: $radius;
  color: white;

  &:hover {
    @include hover-lift;
  }

  .title {
    font-size: 24px;
    margin-bottom: 16px;
  }

  .content {
    opacity: 0.9;
    line-height: 1.6;
  }
}

.button-primary {
  background: $primary;
  border: 2px solid #4f46e5;

  &:hover {
    background: #5558e3;
  }
}`;

const DEFAULT_OUTPUTS: Record<Format, string> = {
  css: DEFAULT_CSS_INPUT,
  scss: "/* compiled output will appear here */",
};

const COMPILE_API = "/api/compile";

const FORMAT_OPTIONS: { value: Format; label: string; ext: string }[] = [
  { value: "css",  label: "CSS",  ext: ".css"  },
  { value: "scss", label: "SCSS", ext: ".scss" },
];

export function Playground() {
  const [format, setFormat]           = useState<Format>("css");
  const [inputs, setInputs]           = useState<Record<Format, string>>({
    css:  DEFAULT_CSS_INPUT,
    scss: DEFAULT_SCSS_INPUT,
  });
  const [css, setCss]                 = useState(DEFAULT_OUTPUTS.css);
  const [copied, setCopied]           = useState(false);
  const [compiling, setCompiling]     = useState(false);
  const [compileError, setCompileError] = useState<string | null>(null);
  const [minify, setMinify]           = useState(false);

  const input = inputs[format];

  const handleFormatChange = (f: Format) => {
    setFormat(f);
    setCompileError(null);
    setCss(DEFAULT_OUTPUTS[f]);
  };

  const handleInputChange = (value: string) => {
    setInputs(prev => ({ ...prev, [format]: value }));
  };

  const handleCompile = async () => {
    setCompileError(null);
    setCompiling(true);
    try {
      const res = await fetch(COMPILE_API, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ input, minify, format }),
      });
      const data = await res.json();
      if (data.error) {
        setCompileError(data.error);
        return;
      }
      if (typeof data.css === "string") setCss(data.css);
    } catch {
      setCompileError("Compile API unavailable. Ensure the server is running with the zigcss binary.");
    } finally {
      setCompiling(false);
    }
  };

  const handleReset = () => {
    setInputs(prev => ({ ...prev, [format]: format === "scss" ? DEFAULT_SCSS_INPUT : DEFAULT_CSS_INPUT }));
    setCss(DEFAULT_OUTPUTS[format]);
    setCompileError(null);
  };

  const handleCopy = async () => {
    await navigator.clipboard.writeText(css);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  };

  const activeFormat = FORMAT_OPTIONS.find(f => f.value === format)!;

  return (
    <div className="min-h-screen py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-7xl mx-auto">
        <div className="text-center mb-8">
          <h1 className="text-4xl mb-4">ZigCSS Playground</h1>
          <p className="text-xl text-slate-600">
            Try CSS &amp; SCSS in your browser. Write code on the left, see the output on the right.
          </p>
        </div>

        {/* Options & Action Buttons */}
        <div className="flex flex-wrap items-center justify-center gap-4 mb-6">

          {/* Format selector */}
          <div className="flex items-center gap-1 bg-slate-100 rounded-lg p-1">
            {FORMAT_OPTIONS.map(opt => (
              <button
                key={opt.value}
                onClick={() => handleFormatChange(opt.value)}
                className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
                  format === opt.value
                    ? "bg-white text-indigo-700 shadow-sm"
                    : "text-slate-500 hover:text-slate-700"
                }`}
              >
                {opt.label}
              </button>
            ))}
          </div>

          {/* Minify toggle */}
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
          {/* Input panel */}
          <div className="bg-white rounded-xl shadow-lg overflow-hidden border border-slate-200">
            <div className="bg-gradient-to-r from-indigo-600 to-purple-600 px-6 py-3 text-white flex items-center justify-between">
              <span>{activeFormat.label} Input</span>
              <span className="text-sm opacity-80">{activeFormat.ext}</span>
            </div>
            <div className="p-4">
              <textarea
                value={input}
                onChange={(e) => handleInputChange(e.target.value)}
                className="w-full h-[600px] font-mono text-sm bg-slate-900 text-slate-100 p-4 rounded-lg focus:outline-none focus:ring-2 focus:ring-indigo-500 resize-none"
                spellCheck={false}
              />
            </div>
          </div>

          {/* Output panel */}
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
            <li>• Switch between <strong>CSS</strong> and <strong>SCSS</strong> using the format selector.</li>
            <li>• SCSS supports variables (<code className="px-2 py-1 bg-white rounded">$var</code>), nesting, and mixins (<code className="px-2 py-1 bg-white rounded">@mixin</code> / <code className="px-2 py-1 bg-white rounded">@include</code>).</li>
            <li>• Check <strong>Minify output</strong> to get compressed CSS.</li>
            <li>• Each format remembers its own input independently.</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
