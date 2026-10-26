// Ebb · ebb.serveka.com. No dependencies.

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Sizes like Finder: decimal units, one decimal from MB up.
function formatBytes(bytes) {
  if (bytes <= 0) return "0 bytes";
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1000 && unit < units.length - 1) { value /= 1000; unit++; }
  return unit < 2 ? `${Math.round(value)} ${units[unit]}` : `${value.toFixed(1)} ${units[unit]}`;
}

// ---------- Nav turns solid once you scroll ----------
const nav = $("#nav");
const onScroll = () => nav.classList.toggle("solid", scrollY > 40);
addEventListener("scroll", onScroll, { passive: true });
onScroll();

// ---------- Copy buttons ----------
for (const button of $$("button.copy")) {
  button.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(button.dataset.copy);
      button.textContent = "Copied";
      button.classList.add("done");
      setTimeout(() => { button.textContent = "Copy"; button.classList.remove("done"); }, 1800);
    } catch {
      button.textContent = "Select it";
    }
  });
}

// ---------- GitHub stars ----------
fetch("https://api.github.com/repos/rajpra808/ebb")
  .then((response) => (response.ok ? response.json() : null))
  .then((repo) => { if (repo && repo.stargazers_count > 0) $("#stars").textContent = repo.stargazers_count.toLocaleString(); })
  .catch(() => {});

// ---------- Reveal on scroll ----------
const revealer = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    entry.target.classList.add("in");
    revealer.unobserve(entry.target);
    entry.target.dispatchEvent(new Event("revealed"));
  }
}, { threshold: 0.18 });
$$(".reveal, #screens").forEach((element) => revealer.observe(element));

// ---------- Hero: a meter of what has gone out with the tide ----------
// Each chip counts once per drift, when it's 80% of the way out to sea.
{
  const sizes = { "node_modules": 1.2e9, ".next/cache": 3.8e8, "DerivedData": 4.6e9, "~/.npm/_cacache": 4.2e8, "Docker-4.30.dmg": 5.45e8, ".venv": 9.44e8 };
  const chips = $$(".chip.out").map((chip) => ({
    bytes: sizes[chip.firstChild.textContent.trim()] || 0,
    duration: parseFloat(chip.style.getPropertyValue("--d")) || 14,
    delay: parseFloat(chip.style.getPropertyValue("--delay")) || 0,
  }));
  const meter = $("#meter");
  const started = performance.now();
  let shown = 0;
  const tick = (now) => {
    const elapsed = (now - started) / 1000;
    const total = chips.reduce((sum, chip) => {
      const trips = Math.floor((elapsed - chip.delay + chip.duration * 0.2) / chip.duration);
      return sum + Math.max(0, trips) * chip.bytes;
    }, 0);
    shown += (total - shown) * 0.08;
    meter.textContent = formatBytes(shown);
    requestAnimationFrame(tick);
  };
  if (reduceMotion) meter.textContent = "8.1 GB"; else requestAnimationFrame(tick);
}

// ---------- Live demo of the review screen ----------
const demoItems = [
  { name: "node_modules", project: "hackathon-bot", path: "~/code/hackathon-bot/node_modules", why: "Project inactive 45 days · no git, editor or agent activity", back: "npm install brings it back", badge: "yes", bytes: 1.2e9 },
  { name: ".venv", project: "scraper", path: "~/code/scraper/.venv", why: "Project inactive 71 days", back: "python3 -m venv .venv, then pip install", badge: "yes", bytes: 9.44e8 },
  { name: "node_modules", project: "old-landing", path: "~/code/old-landing/node_modules", why: "Project inactive 71 days · last commit Aug 15", back: "npm install brings it back", badge: "yes", bytes: 9.43e8 },
  { name: "target", project: "tiny-cli", path: "~/code/tiny-cli/target", why: "Project inactive 71 days", back: "cargo build makes it again", badge: "yes", bytes: 6.71e8 },
  { name: "Docker-4.30.dmg", project: null, path: "~/Downloads/Docker-4.30.dmg", why: "Downloaded 71 days ago", back: null, badge: "re", bytes: 5.45e8 },
  { name: "npm cache", project: null, path: "~/.npm/_cacache", why: "npm cache, last written 71 days ago", back: "refilled on the next install", badge: "yes", bytes: 4.2e8 },
  { name: ".next", project: "portfolio-v2", path: "~/code/portfolio-v2/.next", why: "Project inactive 24 days", back: "rebuilt by next build", badge: "yes", bytes: 3.8e8 },
];
const badgeText = { yes: "Comes back", re: "Re-download", no: "Gone for good" };
let selected = new Set(demoItems.map((_, index) => index));
let removed = new Set();

function renderRows() {
  const rows = $("#rows");
  rows.innerHTML = "";
  demoItems.forEach((item, index) => {
    if (removed.has(index)) return;
    const row = document.createElement("div");
    row.className = "row" + (selected.has(index) ? " sel" : "");
    row.dataset.index = index;
    row.setAttribute("role", "checkbox");
    row.setAttribute("aria-checked", selected.has(index));
    row.tabIndex = 0;
    row.innerHTML = `
      <div class="box"></div>
      <div>
        <div class="name">${item.name}${item.project ? ` <span>in ${item.project}</span>` : ""}</div>
        <div class="path">${item.path}</div>
        <div class="why">${item.why}</div>
        ${item.back ? `<div class="back">Comes back: ${item.back}</div>` : ""}
      </div>
      <span class="badge ${item.badge}">${badgeText[item.badge]}</span>
      <div class="size">${formatBytes(item.bytes)}</div>`;
    const toggle = () => {
      selected.has(index) ? selected.delete(index) : selected.add(index);
      row.classList.toggle("sel");
      row.setAttribute("aria-checked", selected.has(index));
      updateTotals();
    };
    row.addEventListener("click", toggle);
    row.addEventListener("keydown", (event) => { if (event.key === " " || event.key === "Enter") { event.preventDefault(); toggle(); } });
    rows.appendChild(row);
  });
  updateTotals();
}

function updateTotals() {
  const live = demoItems.map((item, index) => ({ item, index })).filter(({ index }) => !removed.has(index));
  const chosen = live.filter(({ index }) => selected.has(index)).map(({ item }) => item);
  const sum = (items) => items.reduce((total, item) => total + item.bytes, 0);
  const total = sum(chosen);
  $("#sel-total").textContent = formatBytes(total);
  $("#sel-count").textContent = `${chosen.length} item${chosen.length === 1 ? "" : "s"}`;
  $("#sel-back").textContent = formatBytes(sum(chosen.filter((item) => item.badge === "yes")));
  $("#sel-re").textContent = formatBytes(sum(chosen.filter((item) => item.badge === "re")));
  $("#list-total").textContent = formatBytes(sum(live.map(({ item }) => item)));
  $("#side-total").textContent = formatBytes(sum(live.map(({ item }) => item)));
  const button = $("#trash");
  button.textContent = total > 0 ? `Move ${formatBytes(total)} to Trash` : "Nothing selected";
  button.disabled = total === 0;
}

function toast(message) {
  const element = $("#toast");
  element.textContent = message;
  element.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => element.classList.remove("show"), 3200);
}

$("#trash").addEventListener("click", () => {
  const going = [...selected].filter((index) => !removed.has(index));
  if (going.length === 0) return;
  const bytes = going.reduce((total, index) => total + demoItems[index].bytes, 0);
  going.forEach((index, order) => {
    const row = $(`.row[data-index="${index}"]`);
    setTimeout(() => row && row.classList.add("gone"), order * 110);
  });
  setTimeout(() => {
    going.forEach((index) => removed.add(index));
    selected = new Set([...selected].filter((index) => !removed.has(index)));
    renderRows();
    toast(`Moved ${going.length} item${going.length === 1 ? "" : "s"} (${formatBytes(bytes)}) to the Trash. Put back any time.`);
  }, going.length * 110 + 750);
});

$("#reset").addEventListener("click", () => {
  removed = new Set();
  selected = new Set(demoItems.map((_, index) => index));
  renderRows();
  toast("Everything is back where it was. That's what History is for.");
});

renderRows();

// ---------- Tools marquee ----------
{
  const first = ["node_modules", ".next", ".turbo", "dist", ".venv", "target", ".build", "Gradle", "DerivedData", "Device support", "Simulators", "Archives"];
  const second = ["npm", "pnpm", "Yarn", "Bun", "pip", "Homebrew", "CocoaPods", "Go modules", "Docker", "Claude Code", "Codex", "Gemini CLI", "Cursor", "Ollama", "LM Studio", "Hugging Face"];
  const fill = (id, names) => {
    const track = $(id);
    const html = names.map((name) => `<span>${name}</span>`).join("");
    track.innerHTML = html + html; // twice, for a seamless loop
  };
  fill("#tools", first);
  fill("#tools2", second);
}

// ---------- Real numbers: count up and fill bars when seen ----------
{
  const figure = $("#figure");
  const target = parseFloat(figure.dataset.to);
  figure.closest(".reveal").addEventListener("revealed", () => {
    const start = performance.now();
    const duration = reduceMotion ? 0 : 1600;
    const step = (now) => {
      const progress = duration ? Math.min(1, (now - start) / duration) : 1;
      const eased = 1 - Math.pow(1 - progress, 3);
      figure.textContent = (target * eased).toFixed(1);
      if (progress < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
  $("#bars").closest(".reveal").addEventListener("revealed", () => {
    $$("#bars .fill").forEach((bar, index) => setTimeout(() => (bar.style.width = bar.dataset.w + "%"), index * 120));
  });
}

// ---------- Signal cards: a glow that follows the pointer ----------
for (const card of $$(".signal")) {
  card.addEventListener("pointermove", (event) => {
    const box = card.getBoundingClientRect();
    card.style.setProperty("--mx", `${event.clientX - box.left}px`);
    card.style.setProperty("--my", `${event.clientY - box.top}px`);
  });
}
