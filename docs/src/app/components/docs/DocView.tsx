import { useParams, Navigate, Link } from "react-router";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

function DocLink({ href, children, ...props }: React.AnchorHTMLAttributes<HTMLAnchorElement>) {
  if (!href) return <a {...props}>{children}</a>;
  const isInternal = href.startsWith("/guide/") || href.startsWith("/api/") || href.startsWith("/examples/");
  const to = isInternal ? `/docs${href}` : href;
  if (isInternal) {
    return <Link to={to} {...props}>{children}</Link>;
  }
  return <a href={href} target="_blank" rel="noopener noreferrer" {...props}>{children}</a>;
}

const docModules = import.meta.glob<string>(
  "../../../content/docs/**/*.md",
  { query: "?raw", import: "default", eager: true }
);

function getContent(slug: string | undefined): string | null {
  if (!slug) return null;
  const normalized = slug.replace(/\/$/, "");
  const key = Object.keys(docModules).find((k) => {
    const extracted = k.replace(/^.*content\/docs\//, "").replace(/\.md$/, "");
    return extracted === normalized;
  });
  if (!key) return null;
  return docModules[key] ?? null;
}

export function DocView() {
  const { "*": slug } = useParams();
  const content = getContent(slug || undefined);

  if (!slug) {
    return <Navigate to="/docs/guide/getting-started" replace />;
  }

  if (!content) {
    return (
      <div className="prose max-w-none">
        <h1>Not found</h1>
        <p>This doc page does not exist.</p>
      </div>
    );
  }

  return (
    <article className="prose prose-slate max-w-none prose-headings:font-semibold prose-a:text-indigo-600 prose-pre:bg-slate-900 prose-pre:text-slate-100">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={{ a: DocLink }}>
        {content}
      </ReactMarkdown>
    </article>
  );
}

