import { spawn } from "child_process";
import fs from "fs";
import path from "path";
import os from "os";

function getZigcssBin() {
  if (process.env.ZIGCSS_BIN) return process.env.ZIGCSS_BIN;
  const localBin = path.join(process.cwd(), "node_modules", ".bin", "zigcss");
  if (fs.existsSync(localBin)) return localBin;
  const winBin = path.join(process.cwd(), "node_modules", ".bin", "zigcss.cmd");
  if (process.platform === "win32" && fs.existsSync(winBin)) return winBin;
  return "zigcss";
}

function getRawBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

export function zigcssCompilePlugin() {
  return {
    name: "zigcss-compile-api",
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const url = req.url?.split("?")[0];
        if (url !== "/api/compile" && url !== "/zigcss/api/compile") {
          return next();
        }
        if (req.method !== "POST") {
          res.statusCode = 405;
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify({ error: "Method not allowed" }));
          return;
        }
        try {
          const raw = await getRawBody(req);
          const { input, minify } = JSON.parse(raw || "{}");
          if (typeof input !== "string") {
            res.statusCode = 400;
            res.setHeader("Content-Type", "application/json");
            res.end(JSON.stringify({ error: "Missing or invalid input" }));
            return;
          }
          const tmpDir = os.tmpdir();
          const id = `zigcss-${Date.now()}-${Math.random().toString(36).slice(2)}`;
          const ext = input.trimStart().startsWith("$") || input.includes("@mixin") ? "scss" : "css";
          const inputPath = path.join(tmpDir, `${id}.${ext}`);
          const outputPath = path.join(tmpDir, `${id}.out.css`);
          fs.writeFileSync(inputPath, input, "utf8");
          const args = [inputPath, "-o", outputPath];
          if (minify) args.push("--minify");
          const result = await new Promise((resolve) => {
            const bin = getZigcssBin();
            const child = spawn(bin, args, {
              stdio: ["ignore", "pipe", "pipe"],
            });
            let stderr = "";
            child.stderr?.on("data", (d) => { stderr += d.toString(); });
            child.on("close", (code) => {
              try {
                fs.unlinkSync(inputPath);
              } catch (_) {}
              if (code === 0 && fs.existsSync(outputPath)) {
                const css = fs.readFileSync(outputPath, "utf8");
                try { fs.unlinkSync(outputPath); } catch (_) {}
                resolve({ css });
              } else {
                resolve({ error: stderr || `zigcss exited with code ${code}` });
              }
            });
            child.on("error", (err) => {
              if (err.code === "ENOENT") {
                resolve({ error: "zigcss not found. Install with: npm install -g zigcss" });
              } else {
                resolve({ error: err.message });
              }
            });
          });
          res.statusCode = 200;
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify(result));
        } catch (err) {
          res.statusCode = 500;
          res.setHeader("Content-Type", "application/json");
          res.end(JSON.stringify({ error: err.message || "Compilation failed" }));
        }
      });
    },
  };
}
