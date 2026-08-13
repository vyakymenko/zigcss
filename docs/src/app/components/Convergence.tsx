import { useEffect, useRef } from "react";

const sourceLabels = ["CSS", "SCSS", "SASS", "LESS", "STYLUS"] as const;

type NavigatorWithMemory = Navigator & { deviceMemory?: number };

function clamp(value: number, minimum = 0, maximum = 1) {
  return Math.min(maximum, Math.max(minimum, value));
}

export function Convergence() {
  const sectionRef = useRef<HTMLElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  useEffect(() => {
    const section = sectionRef.current;
    const canvas = canvasRef.current;
    if (!section || !canvas || typeof IntersectionObserver === "undefined") return;

    const context = canvas.getContext("2d");
    if (!context) return;

    const reducedMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches ?? false;
    const lowMemory = ((navigator as NavigatorWithMemory).deviceMemory ?? 8) <= 4;
    let particleCount = lowMemory || window.innerWidth < 720 ? 20 : 42;
    let animationFrame = 0;
    let active = false;
    let progress = reducedMotion ? 1 : 0;
    let width = 0;
    let height = 0;

    const resize = () => {
      const bounds = canvas.getBoundingClientRect();
      const ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = Math.max(1, bounds.width);
      height = Math.max(1, bounds.height);
      canvas.width = Math.round(width * ratio);
      canvas.height = Math.round(height * ratio);
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
      particleCount = lowMemory || width < 720 ? 20 : 42;
    };

    const updateProgress = () => {
      if (reducedMotion) return;
      const bounds = section.getBoundingClientRect();
      progress = clamp((window.innerHeight - bounds.top) / (window.innerHeight + bounds.height * 0.28));
    };

    const draw = (time: number) => {
      context.clearRect(0, 0, width, height);
      const compact = width < 720;
      const sourceX = compact ? width * 0.12 : width * 0.16;
      const coreX = width * 0.54;
      const outputX = compact ? width * 0.92 : width * 0.86;
      const coreY = height * 0.5;
      const sourceYs = sourceLabels.map((_, index) => height * (0.16 + index * 0.17));

      context.lineCap = "square";
      context.lineWidth = 1;
      for (const sourceY of sourceYs) {
        const elbowX = width * 0.36;
        const lineProgress = clamp(progress * 1.35);
        context.strokeStyle = "rgba(183, 243, 74, 0.25)";
        context.beginPath();
        context.moveTo(sourceX, sourceY);
        context.lineTo(sourceX + (elbowX - sourceX) * lineProgress, sourceY);
        if (lineProgress > 0.55) {
          const secondProgress = clamp((lineProgress - 0.55) / 0.45);
          context.lineTo(elbowX + (coreX - elbowX) * secondProgress, sourceY + (coreY - sourceY) * secondProgress);
        }
        context.stroke();
      }

      context.strokeStyle = "rgba(183, 243, 74, 0.52)";
      context.lineWidth = 2;
      context.beginPath();
      context.moveTo(coreX, coreY);
      context.lineTo(coreX + (outputX - coreX) * clamp((progress - 0.42) * 1.72), coreY);
      context.stroke();

      const movingProgress = reducedMotion ? 0.82 : (time * 0.00013) % 1;
      context.fillStyle = "rgba(183, 243, 74, 0.82)";
      for (let index = 0; index < particleCount; index += 1) {
        const lane = index % sourceYs.length;
        const phase = (movingProgress + index / particleCount) % 1;
        if (phase > progress) continue;
        const sourceY = sourceYs[lane];
        const x = sourceX + (outputX - sourceX) * phase;
        const bend = clamp(phase / 0.58);
        const y = phase < 0.58 ? sourceY + (coreY - sourceY) * bend : coreY;
        context.fillRect(x, y, index % 3 === 0 ? 3 : 2, 2);
      }
    };

    const tick = (time: number) => {
      updateProgress();
      draw(time);
      if (active && !reducedMotion) animationFrame = window.requestAnimationFrame(tick);
    };

    const observer = new IntersectionObserver(([entry]) => {
      active = entry.isIntersecting;
      if (active) {
        window.cancelAnimationFrame(animationFrame);
        animationFrame = window.requestAnimationFrame(tick);
      } else {
        window.cancelAnimationFrame(animationFrame);
      }
    }, { rootMargin: "15% 0px", threshold: 0.05 });

    resize();
    updateProgress();
    draw(0);
    observer.observe(section);
    window.addEventListener("resize", resize, { passive: true });

    return () => {
      observer.disconnect();
      window.cancelAnimationFrame(animationFrame);
      window.removeEventListener("resize", resize);
    };
  }, []);

  return (
    <section ref={sectionRef} id="convergence" className="convergence-section gate-section relative overflow-hidden bg-[#0b110d] text-[#eef5ec]" aria-labelledby="convergence-title">
      <div className="mx-auto max-w-[96rem] px-5 py-28 sm:px-8 md:py-40 lg:px-12">
        <p className="gate-label">── GATE 01 · THE CONVERGENCE ──</p>
        <h2 id="convergence-title" className="display-type mt-7 max-w-6xl text-[clamp(3.3rem,8vw,8.5rem)] leading-[0.82] tracking-[-0.075em]">
          Five languages in. <span className="text-[#b7f34a]">One deterministic compiler out.</span>
        </h2>
        <p className="mt-8 max-w-3xl font-mono text-sm leading-7 text-[#8d9a8b] sm:text-base">
          Native frontends feed one fail-closed Zig core. It validates and emits the final CSS; exact pinned providers remain development-only differential oracles.
        </p>

        <figure className="convergence-stage relative mt-16 h-[34rem] border-y border-[#b7f34a]/15 sm:h-[38rem]" aria-describedby="convergence-description">
          <canvas ref={canvasRef} className="absolute inset-0 size-full" aria-hidden="true" />
          <div className="convergence-source-stack absolute left-0 top-1/2 z-10 flex -translate-y-1/2 flex-col gap-5 sm:left-[4%]">
            {sourceLabels.map(label => <span key={label} className="terminal-node">{label}</span>)}
          </div>
          <div className="convergence-core absolute left-[54%] top-1/2 z-10 -translate-x-1/2 -translate-y-1/2 border border-[#b7f34a]/55 bg-[#101914] px-5 py-8 text-center shadow-[0_0_48px_rgba(183,243,74,0.12)] sm:px-9 sm:py-12">
            <span className="font-mono text-[10px] uppercase tracking-[0.2em] text-[#71806f]">owned result</span>
            <strong className="mt-3 block font-mono text-sm text-[#b7f34a] sm:text-lg">ZIGCSS CORE</strong>
          </div>
          <div className="absolute right-0 top-1/2 z-10 -translate-y-1/2 sm:right-[4%]">
            <span className="terminal-node terminal-node-output">CSS</span>
          </div>
          <figcaption id="convergence-description" className="sr-only">
            CSS, SCSS, indented Sass, Less, and Stylus converge through native Zig language frontends into one ZigCSS core, which emits one deterministic CSS result.
          </figcaption>
        </figure>

        <div className="mt-8 grid gap-5 border-l border-[#b7f34a] pl-5 font-mono text-xs leading-6 text-[#7f8d7d] md:grid-cols-3">
          <p><span className="text-[#b7f34a]">CSS</span> · native-graduated core</p>
          <p><span className="text-[#b7f34a]">SCSS / SASS</span> · native Sass-family frontend</p>
          <p><span className="text-[#b7f34a]">LESS / STYLUS</span> · native Less / Stylus frontends</p>
        </div>
      </div>
    </section>
  );
}
