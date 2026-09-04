import { useParams, Navigate, Link } from "react-router";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

type MarkdownLinkProps = React.AnchorHTMLAttributes<HTMLAnchorElement> & { node?: unknown };

function DocLink({ href, children, node: _node, ...props }: MarkdownLinkProps) {
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
    return <Navigate to="/docs/guide/status" replace />;
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
    <article className="prose prose-slate max-w-none border border-[#d0cbc0] bg-[#faf7ef] p-6 prose-headings:tracking-[-0.025em] prose-a:text-[#36570d] prose-code:before:content-none prose-code:after:content-none prose-pre:bg-[#101914] prose-pre:text-[#f7f3e8] sm:p-9 lg:p-12">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={{ a: DocLink }}>
        {content}
      </ReactMarkdown>
    </article>
  );
}
