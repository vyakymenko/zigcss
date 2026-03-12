import { useState } from "react";
import { Play, Copy, Check, RotateCcw } from "lucide-react";

const DEFAULT_ZIGCSS = `// ZigCSS Syntax
$primary: #6366f1;
$secondary: #8b5cf6;
$spacing: 16px;
$border-radius: 8px;

.card {
  background: linear-gradient(135deg, $primary, $secondary);
  padding: $spacing * 2;
  border-radius: $border-radius;
  color: white;
  
  &:hover {
    transform: translateY(-4px);
    box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2);
  }
  
  .title {
    font-size: 24px;
    margin-bottom: $spacing;
  }
  
  .content {
    opacity: 0.9;
    line-height: 1.6;
  }
}

@mixin button-variant($color) {
  background: $color;
  border: 2px solid darken($color, 10%);
  
  &:hover {
    background: darken($color, 5%);
  }
}

.button-primary {
  @include button-variant($primary);
}`;

const DEFAULT_CSS = `/* Compiled CSS Output */
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

export function Playground() {
  const [zigcss, setZigcss] = useState(DEFAULT_ZIGCSS);
  const [css, setCss] = useState(DEFAULT_CSS);
  const [copied, setCopied] = useState(false);

  const handleCompile = () => {
    // Simulate compilation
    setCss(DEFAULT_CSS);
  };

  const handleReset = () => {
    setZigcss(DEFAULT_ZIGCSS);
    setCss(DEFAULT_CSS);
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
            Try ZigCSS in your browser. Write code on the left, see the compiled output on the right.
          </p>
        </div>

        {/* Action Buttons */}
        <div className="flex flex-wrap justify-center gap-4 mb-6">
          <button
            onClick={handleCompile}
            className="flex items-center gap-2 px-6 py-3 bg-gradient-to-r from-indigo-600 to-purple-600 text-white rounded-lg hover:shadow-lg hover:scale-105 transition-all"
          >
            <Play className="size-5" />
            Compile
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
          {/* ZigCSS Input */}
          <div className="bg-white rounded-xl shadow-lg overflow-hidden border border-slate-200">
            <div className="bg-gradient-to-r from-indigo-600 to-purple-600 px-6 py-3 text-white flex items-center justify-between">
              <span>ZigCSS Input</span>
              <span className="text-sm opacity-80">.zcss</span>
            </div>
            <div className="p-4">
              <textarea
                value={zigcss}
                onChange={(e) => setZigcss(e.target.value)}
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

        {/* Tips */}
        <div className="mt-8 bg-indigo-50 border border-indigo-200 rounded-lg p-6">
          <h3 className="text-lg mb-3 text-indigo-900">💡 Playground Tips</h3>
          <ul className="space-y-2 text-slate-700">
            <li>• Use <code className="px-2 py-1 bg-white rounded">$variable</code> syntax to define variables</li>
            <li>• Nest selectors using <code className="px-2 py-1 bg-white rounded">&</code> for parent reference</li>
            <li>• Create reusable styles with <code className="px-2 py-1 bg-white rounded">@mixin</code> and <code className="px-2 py-1 bg-white rounded">@include</code></li>
            <li>• This is a demo playground - the actual compiler runs natively for maximum performance</li>
          </ul>
        </div>
      </div>
    </div>
  );
}
