// Writes the list of tutorials the dashboard's How-to page shows: apps/dashboard/src/data/howto.generated.json
// (title, section, who it is for, length, and the written steps, which are the spoken lines). Run after the voice and timing are built.
import { readFileSync, writeFileSync } from "node:fs";
const tutorials = JSON.parse(readFileSync("src/tutorials.json", "utf8")), timing = JSON.parse(readFileSync("src/timing.json", "utf8"));
const plain = (t) => t.replace(/(?:\[\[[A-Z]\]\]\s*)+/g, (m) => [...m.matchAll(/\[\[([A-Z])\]\]/g)].map((x) => x[1]).join("") + (/\s$/.test(m) ? " " : ""));
const out = { tutorials: tutorials.map((t) => ({ id: t.id, title: t.title, section: t.section, level: t.level, summary: t.summary, page: t.page, pageLabel: t.pageLabel, seconds: Math.round(timing[t.id].total), steps: t.steps.map((s) => plain(s.voice)) })) };
writeFileSync("../apps/dashboard/src/data/howto.generated.json", JSON.stringify(out, null, 1) + "\n");
console.log(`wrote ${out.tutorials.length} tutorials`);
