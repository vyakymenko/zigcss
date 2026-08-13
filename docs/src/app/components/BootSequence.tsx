import { useEffect, useState } from "react";

const BOOT_SESSION_KEY = "zigcss-terminal-boot-v1";

const bootLines = [
  "determinism gate ........ pass",
  "network policy ......... denied",
  "atomic output .......... armed",
  "five targets ........... matched",
] as const;

function bootWasSeen(): boolean {
  if (typeof window === "undefined") return true;
  if (window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return true;
  try {
    return window.sessionStorage.getItem(BOOT_SESSION_KEY) === "seen";
  } catch {
    return false;
  }
}

export function BootSequence() {
  const [visible, setVisible] = useState(() => !bootWasSeen());

  useEffect(() => {
    if (!visible) return;
    try {
      window.sessionStorage.setItem(BOOT_SESSION_KEY, "seen");
    } catch {
      // The sequence still works when storage is unavailable.
    }
    const timer = window.setTimeout(() => setVisible(false), 1200);
    return () => window.clearTimeout(timer);
  }, [visible]);

  if (!visible) return null;

  return (
    <div
      className="boot-screen fixed inset-0 z-[100] flex cursor-pointer items-center justify-center bg-[#0b110d] px-5 text-[#dfffa0]"
      role="dialog"
      aria-label="ZigCSS boot sequence"
      onClick={() => setVisible(false)}
    >
      <div className="w-full max-w-3xl font-mono">
        <p className="boot-line text-xs uppercase tracking-[0.18em] text-[#73806f]">
          zigcss 0.6.0-rc.2 · deterministic · fail-closed
        </p>
        <div className="mt-8 space-y-3 text-sm sm:text-base">
          {bootLines.map((line, index) => (
            <p key={line} className="boot-line" style={{ animationDelay: `${index * 140}ms` }}>
              <span className="text-[#b7f34a]">[{index + 1}/4]</span> {line}
            </p>
          ))}
        </div>
        <div className="mt-10 flex items-center justify-between border-t border-[#b7f34a]/20 pt-4 text-xs uppercase tracking-[0.16em] text-[#73806f]">
          <span>entering compiler contract<span className="block-caret ml-2 inline-block" aria-hidden="true" /></span>
          <button type="button" className="terminal-link text-[#b7f34a]" onClick={() => setVisible(false)}>
            skip boot
          </button>
        </div>
      </div>
    </div>
  );
}
