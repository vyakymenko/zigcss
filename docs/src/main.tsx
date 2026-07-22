import { createRoot } from "react-dom/client";
import App from "./app/App.tsx";
import "./styles/index.css";

console.info(
  String.raw`%c
 _______       ______  ______  ______
|__  /(_) __ _/ ___/ |/ / ___|/ ___/
  / /| |/ _\` | |   | ' /\___ \\___ \
 / /_| | (_| | |___| . \ ___) |__) |
/____|_|\__, |\____|_|\_\____/____/
        |___/
deterministic · fail-closed · MIT
contribute: github.com/vyakymenko/zigcss`,
  "color:#b7f34a;background:#0b110d;font-family:monospace",
);

createRoot(document.getElementById("root")!).render(<App />);
