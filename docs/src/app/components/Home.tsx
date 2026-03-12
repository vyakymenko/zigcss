import { Link } from "react-router";
import { Zap, Code2, Sparkles, ArrowRight, Terminal, Layers, Rocket } from "lucide-react";

export function Home() {
  return (
    <div className="w-full">
      {/* Hero Section */}
      <section className="relative overflow-hidden">
        <div className="absolute inset-0 bg-gradient-to-br from-indigo-100 via-purple-50 to-pink-100 opacity-60" />
        <div className="relative max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-24 md:py-32">
          <div className="text-center max-w-4xl mx-auto">
            <div className="inline-flex items-center gap-2 px-4 py-2 rounded-full bg-indigo-100 text-indigo-700 mb-6">
              <Sparkles className="size-4" />
              <span className="text-sm">The world&apos;s fastest CSS compiler</span>
            </div>
            
            <h1 className="text-5xl md:text-7xl mb-6 bg-gradient-to-r from-indigo-600 via-purple-600 to-pink-600 bg-clip-text text-transparent">
              ZigCSS
            </h1>
            
            <p className="text-xl md:text-2xl text-slate-600 mb-8 leading-relaxed">
              A zero-dependency CSS compiler built with Zig. Process CSS and preprocessors (SCSS, SASS, LESS, Stylus, PostCSS) 
              with uncompromising performance — 81–127x faster than PostCSS and Sass.
            </p>
            
            <div className="flex flex-col sm:flex-row items-center justify-center gap-4 mb-12">
              <Link
                to="/getting-started"
                className="w-full sm:w-auto px-8 py-4 bg-gradient-to-r from-indigo-600 to-purple-600 text-white rounded-lg hover:shadow-lg hover:scale-105 transition-all flex items-center justify-center gap-2"
              >
                Get Started
                <ArrowRight className="size-5" />
              </Link>
              <Link
                to="/playground"
                className="w-full sm:w-auto px-8 py-4 bg-white text-slate-900 rounded-lg border border-slate-200 hover:border-indigo-300 hover:shadow-md transition-all flex items-center justify-center gap-2"
              >
                Try Playground
                <Code2 className="size-5" />
              </Link>
            </div>

            {/* Code Preview */}
            <div className="bg-slate-900 rounded-xl p-6 text-left shadow-2xl max-w-2xl mx-auto">
              <div className="flex items-center gap-2 mb-4">
                <div className="size-3 rounded-full bg-red-400" />
                <div className="size-3 rounded-full bg-yellow-400" />
                <div className="size-3 rounded-full bg-green-400" />
              </div>
              <pre className="text-sm md:text-base overflow-x-auto">
                <code className="text-slate-300">
                  <span className="text-purple-400">$primary</span>: <span className="text-green-400">#6366f1</span>;{"\n"}
                  <span className="text-purple-400">$spacing</span>: <span className="text-green-400">16px</span>;{"\n\n"}
                  <span className="text-blue-400">.button</span> {"{"}{"\n"}
                  {"  "}background: <span className="text-purple-400">$primary</span>;{"\n"}
                  {"  "}padding: <span className="text-purple-400">$spacing</span>;{"\n"}
                  {"  "}border-radius: <span className="text-green-400">8px</span>;{"\n"}
                  {"  "}&:hover {"{"}{"\n"}
                  {"    "}transform: <span className="text-yellow-400">scale</span>(<span className="text-green-400">1.05</span>);{"\n"}
                  {"  }"}{"}\n"}
                  {"}"}
                </code>
              </pre>
            </div>
          </div>
        </div>
      </section>

      {/* Features Grid */}
      <section className="py-24 bg-white">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="text-center mb-16">
            <h2 className="text-4xl mb-4">Why ZigCSS?</h2>
            <p className="text-xl text-slate-600 max-w-2xl mx-auto">
              Zero-dependency, memory-safe, and built for speed
            </p>
          </div>

          <div className="grid md:grid-cols-3 gap-8">
            <div className="p-8 rounded-xl bg-gradient-to-br from-indigo-50 to-indigo-100 hover:shadow-xl transition-shadow">
              <div className="size-12 bg-indigo-600 rounded-lg flex items-center justify-center mb-4">
                <Zap className="size-6 text-white" />
              </div>
              <h3 className="text-2xl mb-3">Blazingly Fast</h3>
              <p className="text-slate-600">
                Written in Zig for native performance. 81–127x faster than PostCSS and Sass on real-world workloads.
              </p>
            </div>

            <div className="p-8 rounded-xl bg-gradient-to-br from-purple-50 to-purple-100 hover:shadow-xl transition-shadow">
              <div className="size-12 bg-purple-600 rounded-lg flex items-center justify-center mb-4">
                <Layers className="size-6 text-white" />
              </div>
              <h3 className="text-2xl mb-3">Full CSS &amp; Preprocessors</h3>
              <p className="text-slate-600">
                CSS3, nesting, custom properties. Plus SCSS, SASS, LESS, Stylus, PostCSS, and CSS Modules.
              </p>
            </div>

            <div className="p-8 rounded-xl bg-gradient-to-br from-pink-50 to-pink-100 hover:shadow-xl transition-shadow">
              <div className="size-12 bg-pink-600 rounded-lg flex items-center justify-center mb-4">
                <Rocket className="size-6 text-white" />
              </div>
              <h3 className="text-2xl mb-3">Zero Dependencies</h3>
              <p className="text-slate-600">
                Single binary, no runtime requirements. Use as a library or standalone CLI.
              </p>
            </div>
          </div>
        </div>
      </section>

      {/* Stats Section */}
      <section className="py-24 bg-gradient-to-br from-slate-900 to-indigo-900 text-white">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
          <div className="grid md:grid-cols-3 gap-12 text-center">
            <div>
              <div className="text-5xl mb-2 bg-gradient-to-r from-indigo-400 to-purple-400 bg-clip-text text-transparent">
                81–127x
              </div>
              <p className="text-xl text-slate-300">Faster than PostCSS &amp; Sass</p>
            </div>
            <div>
              <div className="text-5xl mb-2 bg-gradient-to-r from-purple-400 to-pink-400 bg-clip-text text-transparent">
                0
              </div>
              <p className="text-xl text-slate-300">Dependencies</p>
            </div>
            <div>
              <div className="text-5xl mb-2 bg-gradient-to-r from-pink-400 to-red-400 bg-clip-text text-transparent">
                100%
              </div>
              <p className="text-xl text-slate-300">Native Performance</p>
            </div>
          </div>
        </div>
      </section>

      {/* CTA Section */}
      <section className="py-24 bg-white">
        <div className="max-w-4xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
          <Terminal className="size-16 mx-auto mb-6 text-indigo-600" />
          <h2 className="text-4xl mb-6">Ready to supercharge your CSS?</h2>
          <p className="text-xl text-slate-600 mb-8">
            Install ZigCSS today and get a single binary, plugin system, and LSP support.
          </p>
          <div className="bg-slate-900 rounded-lg p-6 max-w-2xl mx-auto mb-8">
            <code className="text-green-400 text-lg">
              $ npm install -g zigcss
            </code>
          </div>
          <Link
            to="/getting-started"
            className="inline-flex items-center gap-2 px-8 py-4 bg-gradient-to-r from-indigo-600 to-purple-600 text-white rounded-lg hover:shadow-lg hover:scale-105 transition-all"
          >
            View Documentation
            <ArrowRight className="size-5" />
          </Link>
        </div>
      </section>
    </div>
  );
}
