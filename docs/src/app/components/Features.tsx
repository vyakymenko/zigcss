import { Link } from "react-router";
import { Zap, Code2, Layers, Palette, FileCode, Boxes, Gauge, Shield } from "lucide-react";

export function Features() {
  return (
    <div className="min-h-screen py-12 px-4 sm:px-6 lg:px-8">
      <div className="max-w-6xl mx-auto">
        <div className="text-center mb-16">
          <h1 className="text-4xl mb-4">Powerful Features</h1>
          <p className="text-xl text-slate-600 max-w-3xl mx-auto">
            ZigCSS is a zero-dependency CSS compiler with full CSS3 and preprocessor support
          </p>
        </div>

        {/* Features Grid */}
        <div className="grid md:grid-cols-2 gap-8 mb-16">
          {/* Performance */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-indigo-600 to-indigo-700 rounded-xl flex items-center justify-center mb-6">
              <Zap className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Lightning Fast</h2>
            <p className="text-slate-600 mb-4">
              Written in Zig for native performance. 81–127x faster than PostCSS and Sass for small files; 
              single binary, no runtime overhead.
            </p>
            <ul className="space-y-2 text-slate-700">
              <li className="flex items-start gap-2">
                <span className="text-indigo-600 mt-1">✓</span>
                <span>81–127x faster than PostCSS &amp; Sass</span>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-indigo-600 mt-1">✓</span>
                <span>Zero dependencies</span>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-indigo-600 mt-1">✓</span>
                <span>Native binary execution</span>
              </li>
            </ul>
          </div>

          {/* Variables */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-purple-600 to-purple-700 rounded-xl flex items-center justify-center mb-6">
              <Code2 className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Advanced Variables</h2>
            <p className="text-slate-600 mb-4">
              Define reusable values with support for all CSS data types. Perform calculations and 
              transformations on the fly.
            </p>
            <div className="bg-slate-900 rounded-lg p-4 text-sm">
              <code className="text-slate-100">
                <span className="text-purple-400">$primary</span>: <span className="text-green-400">#6366f1</span>;{"\n"}
                <span className="text-purple-400">$spacing</span>: <span className="text-green-400">16px</span>;{"\n"}
                <span className="text-blue-400">.box</span> {"{"} padding: <span className="text-purple-400">$spacing</span> * 2; {"}"}
              </code>
            </div>
          </div>

          {/* Nesting */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-pink-600 to-pink-700 rounded-xl flex items-center justify-center mb-6">
              <Layers className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Smart Nesting</h2>
            <p className="text-slate-600 mb-4">
              Write clean, hierarchical CSS that mirrors your HTML structure. Use the parent selector 
              for hover states, pseudo-elements, and modifiers.
            </p>
            <div className="bg-slate-900 rounded-lg p-4 text-sm">
              <code className="text-slate-100">
                <span className="text-blue-400">.button</span> {"{"}{"\n"}
                {"  "}&:hover {"{"} transform: scale(1.05); {"}"}{"\n"}
                {"  "}&.primary {"{"} background: blue; {"}"}{"\n"}
                {"}"}
              </code>
            </div>
          </div>

          {/* Mixins */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-green-600 to-green-700 rounded-xl flex items-center justify-center mb-6">
              <Boxes className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Flexible Mixins</h2>
            <p className="text-slate-600 mb-4">
              Create reusable style patterns with parameters. Build your own CSS utility library 
              or design system components.
            </p>
            <div className="bg-slate-900 rounded-lg p-4 text-sm">
              <code className="text-slate-100">
                <span className="text-yellow-400">@mixin</span> <span className="text-blue-400">button</span>($bg) {"{"}{"\n"}
                {"  "}background: $bg;{"\n"}
                {"  "}padding: 12px 24px;{"\n"}
                {"}"}
              </code>
            </div>
          </div>

          {/* Color Functions */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-orange-600 to-orange-700 rounded-xl flex items-center justify-center mb-6">
              <Palette className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Color Functions</h2>
            <p className="text-slate-600 mb-4">
              Powerful color manipulation functions for creating dynamic color schemes. Lighten, darken, 
              mix, and adjust colors programmatically.
            </p>
            <ul className="space-y-2 text-slate-700">
              <li className="flex items-start gap-2">
                <span className="text-orange-600 mt-1">•</span>
                <code>lighten($color, 20%)</code>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-orange-600 mt-1">•</span>
                <code>darken($color, 10%)</code>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-orange-600 mt-1">•</span>
                <code>mix($color1, $color2)</code>
              </li>
            </ul>
          </div>

          {/* Imports */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-blue-600 to-blue-700 rounded-xl flex items-center justify-center mb-6">
              <FileCode className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Modular Architecture</h2>
            <p className="text-slate-600 mb-4">
              Split your styles across multiple files for better organization. Import partials and 
              organize your codebase efficiently.
            </p>
            <div className="bg-slate-900 rounded-lg p-4 text-sm">
              <code className="text-slate-100">
                <span className="text-purple-400">@import</span> <span className="text-green-400">'variables'</span>;{"\n"}
                <span className="text-purple-400">@import</span> <span className="text-green-400">'mixins'</span>;{"\n"}
                <span className="text-purple-400">@import</span> <span className="text-green-400">'components'</span>;
              </code>
            </div>
          </div>

          {/* Source Maps */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-cyan-600 to-cyan-700 rounded-xl flex items-center justify-center mb-6">
              <Gauge className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Developer Tools</h2>
            <p className="text-slate-600 mb-4">
              Built-in source map generation for easy debugging. Watch mode for automatic recompilation. 
              Detailed error messages with line numbers.
            </p>
            <ul className="space-y-2 text-slate-700">
              <li className="flex items-start gap-2">
                <span className="text-cyan-600 mt-1">✓</span>
                <span>Source map support</span>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-cyan-600 mt-1">✓</span>
                <span>Watch mode</span>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-cyan-600 mt-1">✓</span>
                <span>Detailed error reporting</span>
              </li>
            </ul>
          </div>

          {/* Production Ready */}
          <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 hover:shadow-xl transition-shadow">
            <div className="size-14 bg-gradient-to-br from-red-600 to-red-700 rounded-xl flex items-center justify-center mb-6">
              <Shield className="size-7 text-white" />
            </div>
            <h2 className="text-2xl mb-4">Production Ready</h2>
            <p className="text-slate-600 mb-4">
              Built-in minification, autoprefixing, and optimization. Generate production-ready CSS 
              with a single command.
            </p>
            <ul className="space-y-2 text-slate-700">
              <li className="flex items-start gap-2">
                <span className="text-red-600 mt-1">✓</span>
                <span>CSS minification</span>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-red-600 mt-1">✓</span>
                <span>Dead code elimination</span>
              </li>
              <li className="flex items-start gap-2">
                <span className="text-red-600 mt-1">✓</span>
                <span>Optimized output</span>
              </li>
            </ul>
          </div>
        </div>

        {/* Comparison Table */}
        <div className="bg-white rounded-xl p-8 shadow-lg border border-slate-200 mb-12">
          <h2 className="text-3xl mb-8 text-center">How ZigCSS Compares</h2>
          <div className="overflow-x-auto">
            <table className="w-full">
              <thead>
                <tr className="border-b border-slate-200">
                  <th className="text-left py-4 px-4">Feature</th>
                  <th className="text-center py-4 px-4 bg-indigo-50 font-bold">ZigCSS</th>
                  <th className="text-center py-4 px-4">Sass</th>
                  <th className="text-center py-4 px-4">Less</th>
                  <th className="text-center py-4 px-4">Stylus</th>
                </tr>
              </thead>
              <tbody>
                <tr className="border-b border-slate-100">
                  <td className="py-4 px-4">Compilation Speed</td>
                  <td className="text-center py-4 px-4 bg-indigo-50 text-green-600 font-bold">⚡ Ultra Fast</td>
                  <td className="text-center py-4 px-4 text-slate-600">Fast</td>
                  <td className="text-center py-4 px-4 text-slate-600">Fast</td>
                  <td className="text-center py-4 px-4 text-slate-600">Medium</td>
                </tr>
                <tr className="border-b border-slate-100">
                  <td className="py-4 px-4">Variables</td>
                  <td className="text-center py-4 px-4 bg-indigo-50 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                </tr>
                <tr className="border-b border-slate-100">
                  <td className="py-4 px-4">Mixins</td>
                  <td className="text-center py-4 px-4 bg-indigo-50 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                </tr>
                <tr className="border-b border-slate-100">
                  <td className="py-4 px-4">Native Performance</td>
                  <td className="text-center py-4 px-4 bg-indigo-50 text-green-600 font-bold">✓</td>
                  <td className="text-center py-4 px-4 text-slate-400">✗</td>
                  <td className="text-center py-4 px-4 text-slate-400">✗</td>
                  <td className="text-center py-4 px-4 text-slate-400">✗</td>
                </tr>
                <tr className="border-b border-slate-100">
                  <td className="py-4 px-4">Zero Dependencies</td>
                  <td className="text-center py-4 px-4 bg-indigo-50 text-green-600 font-bold">✓</td>
                  <td className="text-center py-4 px-4 text-slate-400">✗</td>
                  <td className="text-center py-4 px-4 text-slate-400">✗</td>
                  <td className="text-center py-4 px-4 text-slate-400">✗</td>
                </tr>
                <tr className="border-b border-slate-100">
                  <td className="py-4 px-4">Control Flow</td>
                  <td className="text-center py-4 px-4 bg-indigo-50 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-slate-400">✗</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                </tr>
                <tr className="border-b border-slate-100">
                  <td className="py-4 px-4">Built-in Functions</td>
                  <td className="text-center py-4 px-4 bg-indigo-50 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                  <td className="text-center py-4 px-4 text-green-600">✓</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        {/* CTA */}
        <div className="bg-gradient-to-br from-indigo-600 to-purple-600 rounded-xl p-8 text-white text-center">
          <h2 className="text-3xl mb-4">Experience the Performance</h2>
          <p className="text-lg mb-6 opacity-90">
            Try ZigCSS today and see the difference native performance makes
          </p>
          <div className="flex flex-col sm:flex-row items-center justify-center gap-4">
            <Link
              to="/getting-started"
              className="px-8 py-3 bg-white text-indigo-600 rounded-lg hover:shadow-lg hover:scale-105 transition-all"
            >
              Get Started
            </Link>
            <Link
              to="/playground"
              className="px-8 py-3 bg-indigo-700 text-white rounded-lg hover:bg-indigo-800 transition-colors"
            >
              Try Playground
            </Link>
          </div>
        </div>
      </div>
    </div>
  );
}
