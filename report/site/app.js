"use strict";

const ORG = "https://github.com/sealhouse";
const STAGES = [
  ["upstream_to_sync", "Upstream to synced", "--s1"],
  ["sync_to_image", "Synced to image built", "--s2"],
  ["image_to_bump", "Image to bump merged", "--s3"],
  ["bump_to_alpha", "Bump to alpha", "--s4"],
];
const charts = [];
let rollup = null;
let zone = "UTC";

const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const $ = (id) => document.getElementById(id);

function el(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else e.setAttribute(k, v);
  }
  for (const k of kids) if (k != null) e.append(k instanceof Node ? k : document.createTextNode(String(k)));
  return e;
}

function link(href, text) {
  return el("a", { href, text });
}

function fmt(n, digits = 0) {
  if (n == null || Number.isNaN(n)) return "–";
  return n.toLocaleString("en", { maximumFractionDigits: digits, minimumFractionDigits: 0 });
}

function zoned(t) {
  const p = {};
  for (const { type, value } of new Intl.DateTimeFormat("en-CA", { timeZone: zone, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date(t))) p[type] = value;
  return { date: `${p.year}-${p.month}-${p.day}`, time: `${p.hour}:${p.minute}` };
}

const stamp = (t) => { const z = zoned(t); return `${z.date.slice(5)} ${z.time}`; };
const dateIn = (t) => zoned(t).date;

function hoursText(h) {
  if (h == null) return "–";
  if (h < 1) return `${Math.round(h * 60)} min`;
  if (h < 48) return `${fmt(h, 1)} h`;
  return `${fmt(h / 24, 1)} days`;
}

function median(xs) {
  const s = xs.filter((x) => x != null).sort((a, b) => a - b);
  if (!s.length) return null;
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function table(container, head, rows, numeric = [], wrap = []) {
  const t = el("table");
  const tr = el("tr");
  head.forEach((h, i) => tr.append(el("th", { class: numeric.includes(i) ? "num" : "", text: h })));
  t.append(el("thead", {}, tr));
  const body = el("tbody");
  for (const r of rows) {
    const row = el("tr");
    r.forEach((c, i) => {
      const td = el("td", { class: numeric.includes(i) ? "num" : wrap.includes(i) ? "wrap" : "" });
      td.append(c instanceof Node ? c : document.createTextNode(c == null ? "–" : String(c)));
      row.append(td);
    });
    body.append(row);
  }
  t.append(body);
  container.replaceChildren(rows.length ? t : el("p", { class: "small", text: "Nothing yet." }));
}

function legend(container, items) {
  container.replaceChildren(...items.map(([label, color]) =>
    el("span", {}, el("b", { style: `background:var(${color})` }), label)));
}

function empty(container, text) {
  container.replaceChildren(el("div", { class: "empty", "data-empty": "1", text }));
}

const crosshair = {
  id: "crosshair",
  afterDatasetsDraw(chart) {
    const a = chart.tooltip && chart.tooltip.getActiveElements();
    if (!a || !a.length || chart.config.type !== "line") return;
    const x = a[0].element.x, { top, bottom } = chart.chartArea, ctx = chart.ctx;
    ctx.save();
    ctx.strokeStyle = css("--axis");
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x, top);
    ctx.lineTo(x, bottom);
    ctx.stroke();
    ctx.restore();
  },
};

function base(type, labels, datasets, opts = {}) {
  const ink2 = css("--ink-2"), grid = css("--grid"), axis = css("--axis"), surface = css("--surface");
  const flat = datasets.every((d) => d.data.every((v) => !v));
  const zeroOnly = (s) => { if (flat) s.ticks = s.ticks.filter((t) => t.value === 0); };
  return {
    type,
    data: { labels, datasets },
    plugins: [crosshair],
    options: {
      responsive: true,
      maintainAspectRatio: false,
      animation: false,
      indexAxis: opts.horizontal ? "y" : "x",
      interaction: { mode: "index", intersect: false, axis: opts.horizontal ? "y" : "x" },
      plugins: {
        legend: { display: false },
        tooltip: {
          backgroundColor: surface, titleColor: css("--ink"), bodyColor: css("--ink"),
          borderColor: css("--ring"), borderWidth: 1, padding: 10, boxWidth: 12, boxHeight: 2,
          usePointStyle: false, callbacks: opts.tooltip || {},
        },
      },
      scales: {
        x: {
          stacked: !!opts.stacked, grid: { display: !!opts.horizontal, color: grid }, border: { color: axis },
          ticks: { color: ink2, maxRotation: 0, autoSkip: true, autoSkipPadding: 12, precision: 0 },
          afterBuildTicks: opts.horizontal ? zeroOnly : undefined,
          title: opts.xTitle ? { display: true, text: opts.xTitle, color: ink2 } : undefined,
        },
        y: {
          stacked: !!opts.stacked, beginAtZero: true, grid: { display: !opts.horizontal, color: grid }, border: { display: false },
          ticks: { color: ink2, precision: 0 },
          afterBuildTicks: opts.horizontal ? undefined : zeroOnly,
        },
      },
    },
  };
}

function bars(label, values, color) {
  return {
    label, data: values, backgroundColor: css(color), borderColor: css("--surface"), borderWidth: 0,
    borderRadius: 4, borderSkipped: "start", maxBarThickness: 24,
  };
}

function lines(label, values, color) {
  return {
    label, data: values, borderColor: css(color), backgroundColor: css(color), borderWidth: 2,
    pointRadius: 4, pointHoverRadius: 5, pointBorderColor: css("--surface"), pointBorderWidth: 2,
    spanGaps: false, tension: 0,
  };
}

// A day still being collected is drawn faded, so its counts so far do not read as a drop.
function soFar(days, dataset) {
  return { ...dataset, backgroundColor: days.map((d) => (d.partial ? `${dataset.backgroundColor}55` : dataset.backgroundColor)) };
}

const dayTitle = (d) => (d.status === "ok" ? `${d.date}${d.partial ? " (so far)" : ""}` : `${d.date} (${d.status === "failed" ? "collection failed" : "no report"})`);

function draw(container, config) {
  const canvas = el("canvas", { role: "img", "aria-label": container.getAttribute("data-label") || "chart" });
  container.replaceChildren(canvas);
  charts.push(new Chart(canvas, config));
}

function stat(n, one, many) {
  return el("div", { class: "stat" }, el("b", { text: fmt(n) }), el("span", { text: n === 1 ? one : many }));
}

function okDays() {
  return rollup.days.filter((d) => d.status === "ok");
}

function tiles() {
  const days = rollup.days.slice(-7);
  const ok = days.filter((d) => d.status === "ok");
  const sum = (k) => ok.reduce((a, d) => a + (d[k] || 0), 0);
  const prs = sum("prs"), hands = sum("hands_off");
  const recent = rollup.alphas.slice(-10).flatMap((a) => a.components.filter((c) => c.upstream && c.upstream.count))
    .map((c) => c.hours.newest_to_alpha);
  const lead = median(recent);
  const note = ok.length === days.length ? `last ${days.length} days` : `last ${days.length} days, ${ok.length} reported`;
  const tile = (cls, label, value, sub) =>
    el("div", { class: `card tile ${cls}` }, el("div", { class: "label", text: label }), el("div", { class: "value", text: value }),
      el("div", { class: "note", text: sub }));
  $("tiles").replaceChildren(
    tile("lead", "Median upstream commit to alpha", lead == null ? "–" : hoursText(lead),
      recent.length ? `over the last ${recent.length} component updates` : "appears once an alpha ships an upstream change"),
    tile("", "Upstream commits synced", fmt(sum("upstream_commits")), note),
    tile("", "Images built", fmt(sum("images")), note),
    tile("", "Alphas published", fmt(sum("alphas")), note),
    tile("", "Merged with no person needed", prs ? `${Math.round((100 * hands) / prs)}%` : "–", prs ? `${hands} of ${prs} PRs, ${note}` : note),
  );
}

function freshness() {
  const at = rollup.last_collected_at ? new Date(rollup.last_collected_at) : null;
  const age = at ? (Date.now() - at.getTime()) / 3600000 : Infinity;
  const [cls, icon, label] = age <= 8 ? ["good", "✓", "Up to date"] : age <= 36 ? ["warning", "!", "Late"] : ["critical", "✕", "Stale"];
  $("fresh").className = `status ${cls}`;
  $("fresh").replaceChildren(el("i", { "aria-hidden": "true", text: icon }), label);
  $("asof").textContent = at ? `last collected ${zoned(at).date} ${zoned(at).time} ${zone} (${hoursText(age)} ago), covering ${rollup.first} to ${rollup.last}` : "never collected";
}

function coverage() {
  $("coverage").replaceChildren(...rollup.days.map((d) => {
    const busy = d.status === "ok" && (d.syncs || d.images || d.alphas || d.prs || d.runs);
    const cls = d.status === "ok" ? (busy ? "ok" : "quiet") : d.status;
    const title = `${d.date}: ${d.status === "ok" ? (d.partial ? "report so far" : busy ? "report" : "report, quiet day") : d.status === "failed" ? "collection failed" : "no report"}`;
    const icon = d.status === "failed" ? "✕" : d.status === "missing" ? "–" : "";
    const href = d.status === "ok" ? `#day/${d.date}` : d.run;
    return href ? el("a", { class: cls, href, title, "aria-label": title, text: icon }) : el("span", { class: cls, title, "aria-label": title, text: icon });
  }));
}

function lead() {
  const rows = rollup.alphas.flatMap((a) => a.components.filter((c) => c.upstream && c.upstream.count).map((c) => ({ a, c })));
  legend($("lead-legend"), STAGES.map(([, l, c]) => [l, c]));
  if (!rows.length) {
    empty($("lead"), "No alpha has shipped an upstream change since collection started.");
    table($("lead-table"), [], []);
    return;
  }
  const labels = rows.map(({ a, c }) => `${a.csv.replace(/^.*\.v/, "v")} · ${c.repo}`);
  const datasets = STAGES.map(([k, l, color], i) => ({
    ...bars(l, rows.map(({ c }) => c.hours[k]), color),
    borderWidth: { right: i < STAGES.length - 1 ? 2 : 0 },
    borderRadius: i === STAGES.length - 1 ? { topRight: 4, bottomRight: 4 } : 0,
    borderSkipped: false,
  }));
  draw($("lead"), base("bar", labels, datasets, {
    horizontal: true, stacked: true, xTitle: "hours",
    tooltip: {
      label: (ctx) => `${hoursText(ctx.raw)}  ${ctx.dataset.label}`,
      footer: (items) => {
        const { c } = rows[items[0].dataIndex];
        return `Total ${hoursText(c.hours.newest_to_alpha)} · ${c.upstream.count} upstream commit${c.upstream.count === 1 ? "" : "s"}`;
      },
    },
  }));
  table($("lead-table"), ["Alpha", "Component", "Upstream commits", ...STAGES.map((s) => s[1]), "Total", "Oldest waited"],
    rows.map(({ a, c }) => [a.csv, c.repo, c.upstream.count, ...STAGES.map(([k]) => hoursText(c.hours[k])),
      hoursText(c.hours.newest_to_alpha), hoursText(c.hours.oldest_to_alpha)]), [2, 3, 4, 5, 6, 7, 8]);
}

function daily() {
  const days = rollup.days, labels = days.map((d) => d.date.slice(5));
  const v = (k) => days.map((d) => (d.status === "ok" ? d[k] : null));
  const tip = { title: (items) => dayTitle(days[items[0].dataIndex]) };
  for (const [id, k, label] of [["upstream", "upstream_commits", "Upstream commits"], ["images", "images", "Images"], ["alphas", "alphas", "Alphas"]]) {
    draw($(id), base("bar", labels, [soFar(days, bars(label, v(k), "--s1"))], { tooltip: tip }));
  }
  table($("daily-table"), ["Day", "Report", "Syncs merged", "Upstream commits", "Images built", "Alphas"],
    days.map((d) => [d.date, d.partial ? "so far" : d.status, d.syncs, d.upstream_commits, d.images, d.alphas]), [2, 3, 4, 5]);
}

function hands() {
  const days = rollup.days, labels = days.map((d) => d.date.slice(5));
  const auto = days.map((d) => (d.status === "ok" ? d.hands_off : null));
  const person = days.map((d) => (d.status === "ok" ? d.prs - d.hands_off : null));
  legend($("hands-legend"), [["No person needed", "--s1"], ["Needed a person", "--s2"]]);
  draw($("hands"), base("bar", labels, [
    soFar(days, { ...bars("No person needed", auto, "--s1"), borderRadius: 0, borderWidth: { top: 2 }, borderSkipped: false }),
    soFar(days, { ...bars("Needed a person", person, "--s2"), borderRadius: { topLeft: 4, topRight: 4 }, borderSkipped: false }),
  ], { stacked: true, tooltip: { title: (items) => dayTitle(days[items[0].dataIndex]) } }));
  table($("hands-table"), ["Day", "Merged PRs", "No person needed", "Needed a person"],
    days.filter((d) => d.status === "ok").map((d) => [`${d.date}${d.partial ? " (so far)" : ""}`, d.prs, d.hands_off, d.prs - d.hands_off]), [1, 2, 3]);
}

function failures() {
  const days = rollup.days;
  draw($("failures"), base("bar", days.map((d) => d.date.slice(5)),
    [soFar(days, bars("Failed runs", days.map((d) => (d.status === "ok" ? d.runs_failed : null)), "--s2"))],
    { tooltip: { title: (items) => dayTitle(days[items[0].dataIndex]) } }));
  const inc = rollup.incidents.slice(-15).reverse();
  table($("incidents"), ["Failed", "Workflow", "Step", "Recovered after"],
    inc.map((i) => [stamp(i.from), el("span", {}, link(i.run, i.workflow), el("br"), el("span", { class: "small", text: i.repo })),
      i.step || "whole run", i.to ? hoursText(i.hours) : el("span", {}, "not yet", el("br"), el("span", { class: "small", text: `to ${rollup.last.slice(5)} UTC` }))]), [3], [1, 2]);
  $("incidents").append(el("p", { class: "small", text: `Times are ${zone}.` }));
}

function nightly() {
  const runs = rollup.nightly;
  if (!runs.length) return empty($("nightly"), "No nightly run in the reported days yet.");
  const names = [...new Set(runs.flatMap((r) => Object.keys(r.jobs)))].filter((n) => !["changes", "record"].includes(n)).sort();
  const t = el("table", { class: "matrix" });
  const head = el("tr", {}, el("th", { text: "Stage" }));
  for (const r of runs) head.append(el("th", { class: "num" }, link(r.url, r.date.slice(5))));
  t.append(el("thead", {}, head));
  const body = el("tbody");
  for (const n of names) {
    const row = el("tr", {}, el("td", { text: n }));
    for (const r of runs) {
      const c = r.jobs[n];
      const [cls, icon, word] = c === "success" ? ["pass", "✓", "passed"] : c === "failure" ? ["fail", "✕", "failed"]
        : c === "skipped" ? ["skip", "–", "skipped, inputs unchanged"] : c ? ["skip", "·", c] : ["skip", "", "not run"];
      row.append(el("td", { class: `cell ${cls}`, title: `${n} ${r.date}: ${word}`, "aria-label": word, text: icon }));
    }
    body.append(row);
  }
  t.append(body);
  $("nightly").replaceChildren(t, el("p", { class: "small", text: "✓ passed · ✕ failed · – skipped because nothing it tests changed" }));
}

function behind() {
  const by = new Map();
  for (const b of rollup.behind) by.set(b.date, (by.get(b.date) || 0) + b.behind);
  const dates = [...by.keys()].sort();
  if (dates.length) draw($("behind"), base("line", dates.map((d) => d.slice(5)), [lines("Waiting commits", dates.map((d) => by.get(d)), "--s1")]));
  else empty($("behind"), "Appears after the first report.");
  const last = dates.length ? rollup.behind.filter((b) => b.date === dates[dates.length - 1]) : [];
  table($("behind-table"), ["Fork", "Waiting commits", "Oldest waiting"],
    last.map((b) => [link(`${ORG}/${b.repo}`, b.repo), b.behind, b.behind ? hoursText(b.age_hours) : "–"]), [1, 2]);
}

function vulns() {
  const v = rollup.vulns;
  legend($("vulns-legend"), [["Fixable", "--s1"], ["Fix baking", "--s2"], ["No fix yet", "--s3"]]);
  if (!v.length) {
    empty($("vulns"), "Appears after the first nightly that records its scan results.");
    table($("vulns-table"), [], []);
    return;
  }
  draw($("vulns"), base("line", v.map((x) => x.date.slice(5)), [lines("Fixable", v.map((x) => x.fix), "--s1"),
    lines("Fix baking", v.map((x) => x.baking), "--s2"), lines("No fix yet", v.map((x) => x.nofix), "--s3")]));
  table($("vulns-table"), ["Night", "Fixable", "Fix baking", "No fix yet", "Repositories scanned"], v.map((x) => [x.date, x.fix, x.baking, x.nofix, x.repos]), [1, 2, 3, 4]);
}

function soak() {
  const s = rollup.soak;
  if (!s.length) {
    empty($("soak-g"), "No soak in the reported days yet.");
    empty($("soak-h"), "No soak in the reported days yet.");
    table($("soak-table"), [], []);
    return;
  }
  const labels = s.map((r) => dateIn(r.date).slice(5));
  draw($("soak-g"), base("line", labels, [lines("Goroutines", s.map((r) => Number(r.goroutines)), "--s1")]));
  draw($("soak-h"), base("line", labels, [lines("Heap MiB", s.map((r) => Number(r.heap_mib)), "--s1")]));
  table($("soak-table"), ["Run", "Alpha", "Kills", "Goroutines", "Heap MiB", "Result"],
    s.map((r) => [stamp(r.date), r.csv, r.kills, r.goroutines, r.heap_mib, r.result]), [2, 3, 4]);
  $("soak-table").append(el("p", { class: "small", text: `Times are ${zone}.` }));
}

function waitingPrs() {
  return rollup.open_prs.filter((p) => p.repo === "ci" || !p.author.endsWith("[bot]"));
}

function attention() {
  const items = [];
  const item = (cls, icon, text, href, more) => items.push(el("li", {}, el("span", { class: `status ${cls}` }, el("i", { "aria-hidden": "true", text: icon })),
    el("span", {}, href ? link(href, text) : text, more ? el("span", { class: "small", text: ` ${more}` }) : null)));
  const open = rollup.incidents.filter((i) => !i.to);
  if (open.length) item("critical", "✕", `${open.length} failing step${open.length === 1 ? "" : "s"} not recovered by the end of ${rollup.last} UTC`, "#reliability",
    open.map((i) => `${i.workflow} (${i.step || "whole run"})`).join(", "));
  const night = rollup.nightly[rollup.nightly.length - 1];
  const broke = night ? Object.entries(night.jobs).filter(([, c]) => c === "failure").map(([n]) => n) : [];
  if (broke.length) item("critical", "✕", `Last nightly, ${night.date}: ${broke.length} stage${broke.length === 1 ? "" : "s"} failed`, "#reliability", broke.join(", "));
  const dates = [...new Set(rollup.behind.map((b) => b.date))].sort();
  const behind = rollup.behind.filter((b) => b.date === dates[dates.length - 1] && b.behind);
  if (behind.length) item("warning", "!", `${behind.length} fork${behind.length === 1 ? "" : "s"} behind upstream`, "#forks",
    behind.map((b) => `${b.repo} ${b.behind}, oldest ${hoursText(b.age_hours)}`).join(" · "));
  const reps = rollup.replaces || [];
  const done = reps.filter((r) => r.condition.released);
  if (done.length) item("warning", "!", `${done.length} replace${done.length === 1 ? "" : "s"} upstream has released the fix for`, "#forks",
    done.map((r) => `${r.module} in ${r.condition.released}`).join(" · "));
  const lag = reps.flatMap((r) => r.consumers.filter((c) => c.state !== "applied").map((c) => `${c.repo} ${r.module}`));
  if (lag.length) item("warning", "!", `${lag.length} fork replace${lag.length === 1 ? "" : "s"} not on replaces.lock's release`, "#forks", lag.join(" · "));
  const w = waitingPrs().length;
  if (w) item("warning", "!", `${w} pull request${w === 1 ? "" : "s"} waiting on a person, listed below`);
  const gaps = rollup.days.slice(-7).filter((d) => d.status !== "ok").length;
  if (gaps) item("warning", "!", `No good report for ${gaps} of the last 7 days`, null, "see report coverage below");
  if (!items.length) item("good", "✓", "Nothing needs attention: every failed step has recovered, the last nightly passed, every fork is up to date and has its replaces, and no pull request waits on a person.");
  $("attention").replaceChildren(...items);
}

function latest() {
  const d = okDays().pop();
  if (!d) return empty($("latest"), "Appears after the first report.");
  $("latest-title").textContent = `Latest day, ${d.date}`;
  $("latest").replaceChildren(
    el("div", { class: "stats" }, stat(d.syncs, "sync merged", "syncs merged"), stat(d.upstream_commits, "upstream commit", "upstream commits"),
      stat(d.images, "image built", "images built"), stat(d.alphas, "alpha", "alphas"), stat(d.prs, "PR merged", "PRs merged"),
      stat(d.runs_failed, "failed run", "failed runs")),
    el("p", { class: "small" }, d.partial ? "This UTC day is still being collected, every hour, so these are its counts so far. " : "",
      link(`#day/${d.date}`, "Open the day report")),
  );
}

function waiting() {
  const w = waitingPrs();
  table($("waiting"), ["Pull request", "Kind", "Opened by", "Open for"],
    w.map((p) => [link(`${ORG}/${p.repo}/pull/${p.pr}`, `${p.repo}#${p.pr} ${p.title}`), p.kind, p.author,
      hoursText((Date.now() - new Date(p.opened_at).getTime()) / 3600000)]), [3]);
}

function carries() {
  const forks = rollup.carries || [];
  if (!forks.length) return empty($("carries"), "Appears after the first report.");
  const pin = (c) => c.label === "drop" && /^Pin ci\b/.test(c.title);
  const n = (f, test) => f.commits.filter(test).length;
  const look = (c) => c.pr && (c.pr.state !== "open" && c.pr.state !== "draft" || c.pr.changed || c.pr.action || !c.pr.carried);
  table($("carries"), ["Fork", "Carries", "Other drops", "Upstream PRs", "PRs to look at", "Pins", "Oldest carry"], forks.map((f) => {
    const kept = f.commits.filter((c) => !pin(c));
    const oldest = kept.reduce((m, c) => (!m || c.at < m ? c.at : m), null);
    return [link(`${ORG}/${f.repo}/commits/rhtas/main`, f.repo), n(f, (c) => c.label === "carry"), n(f, (c) => c.label === "drop" && !pin(c)),
      n(f, (c) => /^[0-9]+$/.test(c.label || "")), n(f, look), n(f, pin), oldest ? dateIn(oldest) : "–"];
  }), [1, 2, 3, 4, 5]);
  const upstream = (pr) => {
    if (!pr) return "–";
    const notes = [pr.state];
    if (pr.action === "remove") notes.push("removed in carries.lock");
    if (pr.action === "replaced-by") notes.push(`replaced by #${pr.replaced_by}`);
    if (!pr.carried) notes.push("no carries.lock line");
    const cell = el("span", {}, link(pr.url, `#${pr.number}`), ` ${notes.join(", ")}`);
    if (pr.changed) cell.append(" · ", link(`${pr.url.replace(/\/pull\/[0-9]+$/, "")}/compare/${pr.carried}...${pr.head}`, "changed since carried"));
    return cell;
  };
  table($("carries-table"), ["Fork", "Commit", "Kind", "Subject", "Upstream PR", "Written"], forks.flatMap((f) => f.commits.map((c, i) =>
    [i === 0 ? f.repo : "", link(`${ORG}/${f.repo}/commit/${c.sha}`, c.sha.slice(0, 12)),
      c.label == null ? "unlabelled" : /^[0-9]+$/.test(c.label) ? `upstream #${c.label}` : c.label, c.title, upstream(c.pr), dateIn(c.at)])), [], [3, 4]);
}

function replaces() {
  const reps = rollup.replaces || [];
  if (!reps.length) {
    table($("replaces-table"), [], []);
    return empty($("replaces"), "ci's replaces.lock has no lines.");
  }
  const drop = (r) => {
    const c = r.condition;
    if (c.kind !== "pr") return `upstream ≥ ${c.want || r.drop.replace(/^upstream>=/, "")}`;
    return el("span", {}, "upstream releases ", c.url ? link(c.url, `#${c.number}`) : `#${c.number}`, ` (${c.state})`);
  };
  const counts = (r) => {
    const ok = r.consumers.filter((c) => c.state === "applied").length;
    const off = r.consumers.filter((c) => c.state !== "applied").map((c) => `${c.repo} ${c.state === "missing" ? "missing" : "on another release"}`);
    return `${ok} of ${r.consumers.length}${off.length ? `; ${off.join(", ")}` : ""}`;
  };
  table($("replaces"), ["Module", "Fork release", "Reason", "Drops when", "Released upstream", "Forks with it"], reps.map((r) =>
    [r.module, link(`${ORG}/${r.fork_module.split("/")[2]}/tags`, r.version), r.reason, drop(r),
      r.condition.released ? `${r.condition.released}, its replace can go` : r.condition.state === "unknown" ? "lookup failed" : "not yet", counts(r)]), [], [2, 5]);
  const open = rollup.open_prs.filter((p) => p.kind === "replaces");
  $("replaces").append(el("p", { class: "small" }, open.length ? `${open.length} replaces pull request${open.length === 1 ? "" : "s"} open: ` : "No replaces pull request is open.",
    ...open.flatMap((p, i) => [i ? ", " : "", link(`${ORG}/${p.repo}/pull/${p.pr}`, `${p.repo}#${p.pr}`)])));
  table($("replaces-table"), ["Module", "Fork", "go.mod", "Replaced by", "State"], reps.flatMap((r) => r.consumers.flatMap((c) => c.files.map((f, i) =>
    [i === 0 ? r.module : "", i === 0 ? link(`${ORG}/${c.repo}/blob/rhtas/main/${f.path}`, c.repo) : "", f.path, f.replaced,
      f.state === "applied" ? "applied" : f.state === "missing" ? "missing" : "another release"]))), [], [3]);
}

async function dayview(date) {
  const box = $("dayview");
  const d = rollup.days.find((x) => x.date === date);
  if (!d || d.status !== "ok") {
    box.replaceChildren(el("p", { class: "small", text: d && d.status === "failed" ? "Collection failed for this day." : "No report for this day." }));
    return;
  }
  const r = await (await fetch(`data/daily/${date}.json`)).json();
  const time = (t) => { if (!t) return "–"; const z = zoned(t); return z.date === date ? z.time : `${z.date.slice(5)} ${z.time}`; };
  const pr = (repo, n) => link(`${ORG}/${repo}/pull/${n}`, `${repo}#${n}`);
  const fold = (title, n, ...body) => el("details", { class: "dsec", open: "" },
    el("summary", {}, el("h3", { text: `${title} (${n})` })), ...(n ? body : [el("p", { class: "small", text: "None." })]));
  const section = (title, rows, build) => {
    const box = el("div", { class: "scroll" });
    if (rows.length) build(box);
    return fold(title, rows.length, box);
  };
  const syncs = [...r.syncs].sort((a, b) => (a.closed_at || "").localeCompare(b.closed_at || ""));
  const images = r.images.filter((i) => i.pushed);
  const merged = r.prs.filter((p) => p.merged).sort((a, b) => a.closed_at.localeCompare(b.closed_at));
  const failed = r.runs.filter((x) => x.conclusion === "failure");
  const kinds = [...new Set(merged.map((p) => p.kind))].sort();
  const upstream = syncs.reduce((n, s) => n + (s.merged && s.upstream ? s.upstream.count : 0), 0);
  const prs = el("div", { class: "scroll" });
  table(prs, ["Kind", "Merged", "No person needed"], kinds.map((k) => {
    const of = merged.filter((p) => p.kind === k);
    return [k, of.length, of.filter((p) => p.hands_off).length];
  }), [1, 2]);
  const lists = kinds.map((k) => {
    const d = el("details", {}, el("summary", { text: `${k} pull requests` }));
    const box = el("div", { class: "scroll" });
    table(box, ["Merged", "Pull request", "Title", "Approved by"], merged.filter((p) => p.kind === k).map((p) =>
      [time(p.closed_at), pr(p.repo, p.pr), p.title, p.approved_by.length ? p.approved_by.join(", ") : "no one"]), [], [2]);
    d.append(box);
    return d;
  });
  box.replaceChildren(
    el("div", { class: "stats" }, stat(syncs.filter((s) => s.merged).length, "sync merged", "syncs merged"),
      stat(upstream, "upstream commit", "upstream commits"), stat(images.length, "image built", "images built"),
      stat(r.alphas.length, "alpha", "alphas"), stat(merged.length, "PR merged", "PRs merged"), stat(failed.length, "failed run", "failed runs")),
    el("p", { class: "small", text: zone === "UTC" ? "Times are UTC." :
      `The day runs midnight to midnight UTC. Times are ${zone}, with the date shown when it falls on another day there.` }),
    section("Alphas", r.alphas, (b) => table(b, ["Published", "Alpha", "Ships"], r.alphas.map((a) =>
      [time(a.at), a.csv.replace(/^secure-sign-pqc-operator\./, ""), a.components.length ? a.components.map((c) => (c.upstream && c.upstream.count
        ? `${c.repo} (${c.upstream.count} upstream commit${c.upstream.count === 1 ? "" : "s"})` : `${c.repo} (rebuild, no new upstream commits)`)).join(", ")
        : "operator change only"]), [], [2])),
    section("Syncs", syncs, (b) => table(b, ["Closed", "Pull request", "Upstream commits", "Result"], syncs.map((s) =>
      [time(s.closed_at), pr(s.repo, s.pr), s.upstream ? s.upstream.count : "–", s.merged ? "merged" : "closed unmerged"]), [2])),
    section("Images built", images, (b) => table(b, ["Built", "Image", "Commit", "Digest"], images.map((i) =>
      [time(i.at), link(i.run, i.image), i.commit.slice(0, 12), i.digest.slice(7, 19)]))),
    fold("Merged pull requests", merged.length, prs, ...lists),
    section("Failed runs", failed, (b) => table(b, ["Started", "Workflow", "Failed step"], failed.map((x) => {
      const steps = Object.entries(x.steps || {}).filter(([, c]) => c === "failure").map(([s]) => s);
      return [time(x.created_at), el("span", {}, link(x.url, x.workflow), el("br"), el("span", { class: "small", text: x.repo })),
        steps.length ? steps.join(", ") : "whole run"];
    }), [], [1, 2])),
    el("p", { class: "small" }, "Collected by ", r.run.url ? link(r.run.url, `run ${r.run.id}`) : "a local run", ` at ${zoned(r.run.collected_at).date} ${zoned(r.run.collected_at).time} ${zone}.`),
  );
}

function render() {
  while (charts.length) charts.pop().destroy();
  Chart.defaults.font.family = 'system-ui, -apple-system, "Segoe UI", sans-serif';
  Chart.defaults.color = css("--ink-2");
  freshness();
  tiles();
  attention();
  latest();
  coverage();
  lead();
  daily();
  hands();
  failures();
  nightly();
  behind();
  vulns();
  soak();
  carries();
  replaces();
  waiting();
}

function theme() {
  const order = ["auto", "light", "dark"];
  let t = "auto";
  try { t = localStorage.getItem("theme") || "auto"; } catch (e) { /* storage may be blocked */ }
  const apply = () => {
    if (t === "auto") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = t;
    $("theme").textContent = `Theme: ${t}`;
  };
  apply();
  $("theme").addEventListener("click", () => {
    t = order[(order.indexOf(t) + 1) % order.length];
    try { localStorage.setItem("theme", t); } catch (e) { /* storage may be blocked */ }
    apply();
    if (rollup) render();
  });
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => rollup && render());
}

function zones() {
  const local = Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  const all = typeof Intl.supportedValuesOf === "function" ? Intl.supportedValuesOf("timeZone") : [];
  const known = (z) => { try { new Intl.DateTimeFormat("en", { timeZone: z }); return true; } catch (e) { return false; } };
  try { zone = localStorage.getItem("zone") || "UTC"; } catch (e) { /* storage may be blocked */ }
  if (!known(zone)) zone = "UTC";
  const list = [...new Set(["UTC", local, zone, ...all])];
  $("zone").replaceChildren(...list.map((z) => el("option", { value: z, text: z === local && z !== "UTC" ? `${z} (this device)` : z })));
  $("zone").value = zone;
  $("zone").addEventListener("change", (e) => {
    zone = e.target.value;
    try { localStorage.setItem("zone", zone); } catch (e2) { /* storage may be blocked */ }
    if (!rollup) return;
    render();
    if ($("day").value) dayview($("day").value);
  });
}

function show() {
  const [name, date] = location.hash.slice(1).split("/");
  const tab = $(`tab-${name}`) ? name : "overview";
  for (const a of document.querySelectorAll("[data-tab]")) {
    if (a.dataset.tab === tab) a.setAttribute("aria-selected", "true");
    else a.removeAttribute("aria-selected");
  }
  for (const p of document.querySelectorAll(".tabpanel")) p.hidden = p.id !== `tab-${tab}`;
  for (const c of charts) c.resize();
  if (tab === "day" && date && rollup && date !== $("day").value && okDays().some((d) => d.date === date)) {
    $("day").value = date;
    dayview(date);
  }
}

async function main() {
  theme();
  zones();
  show();
  addEventListener("hashchange", show);
  try {
    const res = await fetch("data/rollup.json", { cache: "no-cache" });
    if (!res.ok) throw new Error(`data/rollup.json: HTTP ${res.status}`);
    rollup = await res.json();
    if (rollup.schema !== 1) throw new Error(`data/rollup.json has schema ${rollup.schema}, this page reads 1`);
    render();
    const ok = okDays().map((d) => d.date).reverse();
    $("day").replaceChildren(...ok.map((d) => el("option", { value: d, text: d })));
    $("day").addEventListener("change", (e) => { history.replaceState(null, "", `#day/${e.target.value}`); dayview(e.target.value); });
    const [, asked] = location.hash.slice(1).split("/");
    if (ok.length) {
      const date = ok.includes(asked) ? asked : ok[0];
      $("day").value = date;
      await dayview(date);
    }
    document.body.dataset.charts = String(charts.length);
    document.body.dataset.ready = "ok";
  } catch (e) {
    $("error-text").textContent = String(e && e.message ? e.message : e);
    document.body.dataset.ready = "error";
    console.error(e);
  }
}

main();
