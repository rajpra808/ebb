// Ebb · ebb.serveka.com. No dependencies.

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const reduceMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

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
}, { threshold: 0.15 });
$$(".reveal").forEach((element) => revealer.observe(element));

// ---------- Hero: the daily moment, on a loop ----------
// A notification arrives, the cursor clicks it, the panel opens, and one
// press of Move to Trash clears it. Then the next day starts.
{
  const mac = $("#mac");
  const notice = $("#notice");
  const panel = $("#panel");
  const go = $("#go");
  const cursor = $("#cursor");
  const caption = $("#caption");
  const item = $("#ebb-item");
  const size = $("#item-size");

  // Positions in % of the Mac, relative to the element's box.
  const pointAt = (element, fx = 0.5, fy = 0.5) => {
    const box = element.getBoundingClientRect();
    const frame = mac.getBoundingClientRect();
    cursor.style.left = ((box.left + box.width * fx - frame.left) / frame.width) * 100 + "%";
    cursor.style.top = ((box.top + box.height * fy - frame.top) / frame.height) * 100 + "%";
  };
  const say = (step, text) => { caption.innerHTML = `<i>${step}</i><span>${text}</span>`; };

  const reset = () => {
    notice.classList.remove("show", "pressed");
    panel.classList.remove("show", "cleaned");
    $$(".it", panel).forEach((row) => row.classList.remove("gone"));
    item.classList.remove("on");
    size.textContent = "6.2 GB";
    cursor.style.left = "38%";
    cursor.style.top = "74%";
  };

  const play = async () => {
    for (;;) {
      reset();
      say(1, "Once a day, one notification");
      await wait(900);
      notice.classList.add("show");
      await wait(1700);
      pointAt(notice, 0.55, 0.55);
      await wait(1100);
      notice.classList.add("pressed");
      await wait(220);
      notice.classList.remove("show");
      item.classList.add("on");
      panel.classList.add("show");
      say(2, "Click it: what's safe, and whether it regenerates");
      await wait(2400);
      pointAt(go, 0.5, 0.5);
      await wait(1100);
      say(3, "One press. It goes to the Trash");
      go.classList.add("pressed");
      await wait(180);
      go.classList.remove("pressed");
      $$(".it", panel).forEach((row, index) => setTimeout(() => row.classList.add("gone"), index * 140));
      await wait(800);
      panel.classList.add("cleaned");
      size.textContent = "";
      await wait(2600);
      say(4, "Done. Back to work");
      panel.classList.remove("show");
      item.classList.remove("on");
      cursor.style.left = "40%";
      cursor.style.top = "70%";
      await wait(2200);
    }
  };

  if (reduceMotion) {
    notice.classList.add("show");
    say(1, "Once a day, one notification");
  } else {
    // Start when the hero is visible, so the first loop isn't missed.
    const start = new IntersectionObserver((entries) => {
      if (entries.some((entry) => entry.isIntersecting)) { start.disconnect(); play(); }
    });
    start.observe(mac);
  }
}

// ---------- Numbers: fill the bars when seen ----------
{
  const bars = $("#bars");
  bars.closest(".reveal").addEventListener("revealed", () => {
    $$(".f", bars).forEach((bar, index) => setTimeout(() => (bar.style.width = bar.dataset.w + "%"), index * 120));
  });
  const figure = $("#figure");
  const target = parseFloat(figure.dataset.to);
  figure.closest(".reveal").addEventListener("revealed", () => {
    if (reduceMotion) return;
    const started = performance.now();
    const step = (now) => {
      const progress = Math.min(1, (now - started) / 1400);
      figure.textContent = (target * (1 - Math.pow(1 - progress, 3))).toFixed(1);
      if (progress < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}
