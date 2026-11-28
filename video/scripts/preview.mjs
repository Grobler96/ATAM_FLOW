// Renders one still per step (late enough in the step that its pop-ups and captions have appeared) and tiles them into out/preview/<id>.png,
// so a whole video can be checked at a glance without rendering it. Bundles once, so it is much quicker than `remotion still` per frame.
// Usage: node scripts/preview.mjs <id> [<id> ...]      (BROWSER may point at a Chrome/Chromium headless shell)
import { bundle } from "@remotion/bundler";
import { renderStill, selectComposition } from "@remotion/renderer";
import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
import path from "node:path";
let browserExecutable = process.env.BROWSER || null;
if (!browserExecutable && existsSync("/opt/pw-browsers")) browserExecutable = readdirSync("/opt/pw-browsers").filter((x) => x.startsWith("chromium_headless_shell-")).map((d) => `/opt/pw-browsers/${d}/chrome-headless-shell-linux64/chrome-headless-shell`).find(existsSync) ?? null;
const timing = JSON.parse(readFileSync("src/timing.json", "utf8"));
const ids = process.argv.slice(2);
const serveUrl = await bundle({ entryPoint: path.resolve("src/index.ts") });
mkdirSync("out/preview", { recursive: true });
for (const id of ids) {
  const comp = await selectComposition({ serveUrl, id, browserExecutable });
  const dir = `out/preview/${id}`; mkdirSync(dir, { recursive: true });
  const files = [];
  for (const [i, s] of timing[id].steps.entries()) {
    const t = s.start + s.voice * 0.72, frame = Math.min(comp.durationInFrames - 1, Math.round(t * 30)), output = `${dir}/${i}.png`;
    await renderStill({ composition: comp, serveUrl, frame, output, imageFormat: "png", browserExecutable, scale: 0.5 });
    files.push(output);
  }
  const cols = 3, rows = Math.ceil(files.length / cols);
  execSync(`ffmpeg -y -loglevel error ${files.map((f) => `-i ${f}`).join(" ")} -filter_complex "${files.map((_, i) => `[${i}]scale=640:-1[s${i}]`).join(";")};${files.map((_, i) => `[s${i}]`).join("")}xstack=inputs=${files.length}:layout=${files.map((_, i) => `${(i % cols) * 640}_${Math.floor(i / cols) * 360}`).join("|")}" out/preview/${id}.png`);
  console.log(`out/preview/${id}.png (${rows} rows)`);
}
