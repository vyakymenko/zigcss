import { Link } from "react-router";
import { Terminal, Download, FileCode, Zap, CheckCircle } from "lucide-react";

export function GettingStarted() {
  return (
    <div className="min-h-screen py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-4xl mx-auto">
        <div className="text-center mb-12">
          <h1 className="text-4xl mb-4">Getting Started</h1>
          <p className="text-xl text-slate-600">
            Get up and running with ZigCSS in minutes
          </p>
        </div>

        {/* Installation */}
        <section className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 mb-8">
          <div className="flex items-center gap-3 mb-6">
            <Download className="size-7 text-indigo-600" />
            <h2 className="text-3xl">Installation</h2>
          </div>

          <p className="text-slate-700 mb-6 text-lg">
            Install ZigCSS via npm, Homebrew, or from source. The npm package downloads the appropriate binary for your platform.
          </p>

          <div className="space-y-4">
            <div className="bg-slate-900 rounded-lg p-6">
              <div className="flex items-center justify-between mb-2">
                <span className="text-slate-400 text-sm">npm</span>
              </div>
              <code className="text-green-400">npm install -g zigcss</code>
            </div>

            <div className="bg-slate-900 rounded-lg p-6">
              <div className="flex items-center justify-between mb-2">
                <span className="text-slate-400 text-sm">Homebrew (macOS)</span>
              </div>
              <code className="text-green-400">brew tap vyakymenko/zigcss</code>
              <br />
              <code className="text-green-400">brew install zigcss</code>
            </div>

            <div className="bg-slate-900 rounded-lg p-6">
              <div className="flex items-center justify-between mb-2">
                <span className="text-slate-400 text-sm">From source (Zig 0.15.2+)</span>
              </div>
              <code className="text-green-400">git clone https://github.com/vyakymenko/zigcss.git &amp;&amp; cd zigcss &amp;&amp; zig build -Doptimize=ReleaseFast</code>
            </div>
          </div>

          <p className="mt-4 text-slate-600 text-sm">
            Pre-built binaries: <a href="https://github.com/vyakymenko/zigcss/releases" className="text-indigo-600 hover:underline" target="_blank" rel="noopener noreferrer">releases</a>. Verify with <code className="px-1.5 py-0.5 bg-slate-100 rounded">zigcss --version</code>.
          </p>
        </section>

        {/* Quick Start */}
        <section className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 mb-8">
          <div className="flex items-center gap-3 mb-6">
            <Zap className="size-7 text-purple-600" />
            <h2 className="text-3xl">Quick Start</h2>
          </div>

          <ol className="space-y-6">
            <li className="flex gap-4">
              <div className="flex-shrink-0 size-8 bg-purple-100 text-purple-600 rounded-full flex items-center justify-center">
                1
              </div>
              <div className="flex-1">
                <h3 className="text-xl mb-2">Create a CSS or preprocessor file</h3>
                <p className="text-slate-600 mb-3">
                  Use <code className="px-2 py-1 bg-slate-100 rounded">.css</code>, <code className="px-2 py-1 bg-slate-100 rounded">.scss</code>, <code className="px-2 py-1 bg-slate-100 rounded">.less</code>, <code className="px-2 py-1 bg-slate-100 rounded">.styl</code>, or other supported formats.
                </p>
              </div>
            </li>

            <li className="flex gap-4">
              <div className="flex-shrink-0 size-8 bg-purple-100 text-purple-600 rounded-full flex items-center justify-center">
                2
              </div>
              <div className="flex-1">
                <h3 className="text-xl mb-2">Compile to CSS</h3>
                <p className="text-slate-600 mb-3">
                  Basic compilation:
                </p>
                <div className="bg-slate-900 rounded-lg p-4">
                  <code className="text-green-400">zigcss input.css -o output.css</code>
                </div>
                <p className="text-slate-600 mt-3">With optimizations and minification:</p>
                <div className="bg-slate-900 rounded-lg p-4 mt-2">
                  <code className="text-green-400">zigcss input.css -o output.css --optimize --minify</code>
                </div>
              </div>
            </li>

            <li className="flex gap-4">
              <div className="flex-shrink-0 size-8 bg-purple-100 text-purple-600 rounded-full flex items-center justify-center">
                3
              </div>
              <div className="flex-1">
                <h3 className="text-xl mb-2">Watch and develop</h3>
                <p className="text-slate-600 mb-3">
                  Recompile on change:
                </p>
                <div className="bg-slate-900 rounded-lg p-4">
                  <code className="text-green-400">zigcss input.css -o output.css --watch</code>
                </div>
              </div>
            </li>

            <li className="flex gap-4">
              <div className="flex-shrink-0 size-8 bg-green-500 text-white rounded-full flex items-center justify-center">
                <CheckCircle className="size-5" />
              </div>
              <div className="flex-1">
                <h3 className="text-xl mb-2">Done!</h3>
                <p className="text-slate-600">
                  Your compiled CSS file is ready to use in your project.
                </p>
              </div>
            </li>
          </ol>
        </section>

        {/* CLI Options */}
        <section className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 mb-8">
          <div className="flex items-center gap-3 mb-6">
            <Terminal className="size-7 text-pink-600" />
            <h2 className="text-3xl">CLI Options</h2>
          </div>

          <div className="space-y-4">
            <div className="border border-slate-200 rounded-lg p-4">
              <code className="text-indigo-600">zigcss input.css -o output.css</code>
              <p className="text-slate-600 mt-2">Compile a single file</p>
            </div>

            <div className="border border-slate-200 rounded-lg p-4">
              <code className="text-indigo-600">zigcss input.css -o output.css --watch</code>
              <p className="text-slate-600 mt-2">Watch for changes and recompile automatically</p>
            </div>

            <div className="border border-slate-200 rounded-lg p-4">
              <code className="text-indigo-600">zigcss input.css -o output.css --optimize --minify</code>
              <p className="text-slate-600 mt-2">Optimize and minify the output</p>
            </div>

            <div className="border border-slate-200 rounded-lg p-4">
              <code className="text-indigo-600">zigcss input.css -o output.css --source-map</code>
              <p className="text-slate-600 mt-2">Generate source maps for debugging</p>
            </div>

            <div className="border border-slate-200 rounded-lg p-4">
              <code className="text-indigo-600">zigcss input.css -o output.css --autoprefix</code>
              <p className="text-slate-600 mt-2">Add vendor prefixes automatically</p>
            </div>
          </div>
        </section>

        {/* Build integration */}
        <section className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 mb-8">
          <div className="flex items-center gap-3 mb-6">
            <FileCode className="size-7 text-green-600" />
            <h2 className="text-3xl">Build Integration</h2>
          </div>

          <p className="text-slate-700 mb-6">
            Use ZigCSS in your build via scripts or the Zig build system.
          </p>

          <div className="space-y-6">
            <div>
              <h3 className="text-xl mb-3">Package.json scripts</h3>
              <div className="bg-slate-900 rounded-lg p-4">
                <pre className="text-slate-100 overflow-x-auto">
                  <code>{`{
  "scripts": {
    "build:css": "zigcss src/styles.css -o dist/styles.css",
    "watch:css": "zigcss src/styles.css -o dist/styles.css --watch",
    "build:css:prod": "zigcss src/styles.css -o dist/styles.min.css --optimize --minify"
  }
}`}</code>
                </pre>
              </div>
            </div>

            <div>
              <h3 className="text-xl mb-3">Zig build system</h3>
              <p className="text-slate-600 mb-3">
                Add ZigCSS as a dependency and use <code className="px-1.5 py-0.5 bg-slate-100 rounded">build_helpers.zig</code> in your <code className="px-1.5 py-0.5 bg-slate-100 rounded">build.zig</code> to compile CSS as part of <code className="px-1.5 py-0.5 bg-slate-100 rounded">zig build</code>. See the <Link to="/docs/guide/build-integration" className="text-indigo-600 hover:underline">Build Integration</Link> guide for details.
              </p>
            </div>
          </div>
        </section>

        {/* Next Steps */}
        <div className="bg-gradient-to-br from-indigo-600 to-purple-600 rounded-xl p-8 text-white">
          <h2 className="text-3xl mb-4">Next Steps</h2>
          <ul className="space-y-3 mb-6">
            <li className="flex items-center gap-3">
              <CheckCircle className="size-5" />
              <span>Read the full documentation</span>
            </li>
            <li className="flex items-center gap-3">
              <CheckCircle className="size-5" />
              <span>Try the interactive playground</span>
            </li>
            <li className="flex items-center gap-3">
              <CheckCircle className="size-5" />
              <span>Explore advanced features</span>
            </li>
            <li className="flex items-center gap-3">
              <CheckCircle className="size-5" />
              <span>Join the community on GitHub</span>
            </li>
          </ul>
          <a
            href="https://github.com/vyakymenko/zigcss"
            target="_blank"
            rel="noopener noreferrer"
            className="inline-block px-6 py-3 bg-white text-indigo-600 rounded-lg hover:shadow-lg hover:scale-105 transition-all"
          >
            View on GitHub
          </a>
        </div>
      </div>
    </div>
  );
}
