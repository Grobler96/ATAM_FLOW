// Renders tutorials to out/<id>.mp4, or stills to look at them.
// Usage: node scripts/render.mjs [id ...]            render videos (all if none given)
//        node scripts/render.mjs --posters           still images for the How-to page
//        node scripts/render.mjs --stills <id> s,s,s  render stills at those seconds into out/stills/<id>/
// Remotion needs a Chrome: set BROWSER, or it uses the Playwright Chromium if present.
import { execSync } from "node:child_process";
import { readFileSync, readdirSync, existsSync, mkdirSync } from "node:fs";
const ids = JSON.parse(readFileSync("src/tutorials.json", "utf8")).map((t) => t.id);
let browser = process.env.BROWSER;
if (!browser && existsSync("/opt/pw-browsers")) { const c = readdirSync("/opt/pw-browsers").filter((x) => x.startsWith("chromium_headless_shell-")).map((d) => `/opt/pw-browsers/${d}/chrome-headless-shell-linux64/chrome-headless-shell`).find(existsSync); if (c) browser = c; }
const b = browser ? `--browser-executable=${browser}` : "";
const args = process.argv.slice(2);
if (args[0] === "--posters") {   // one still per tutorial for the How-to page: apps/dashboard/public/howto/<id>.jpg
  // the still is taken once the first caption line is complete
  const timing = JSON.parse(readFileSync("src/timing.json", "utf8")); mkdirSync("../apps/dashboard/public/howto", { recursive: true });
  for (const id of ids) execSync(`npx remotion still src/index.ts ${id} ../apps/dashboard/public/howto/${id}.jpg --frame=${Math.round((timing[id].steps[1].end - 0.45) * 30)  } --image-format=jpeg --jpeg-quality=78 --scale=0.5 ${b}`, { stdio: "inherit" });
} else if (args[0] === "--stills") {
  const [, id, secs] = args; mkdirSync(`out/stills/${id}`, { recursive: true });
  for (const s of secs.split(",")) execSync(`npx remotion still src/index.ts ${id} out/stills/${id}/${String(s).replace(".", "_")}s.png --frame=${Math.round(Number(s) * 30)} ${b}`, { stdio: "inherit" });
} else {
  for (const id of args.length ? args : ids) execSync(`npx remotion render src/index.ts ${id} out/${id}.mp4 --crf=18 --audio-codec=aac ${b}`, { stdio: "inherit" });
}
