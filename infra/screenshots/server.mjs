// Screenshot service for Acervo, run as a Sprite service (see README.md).
//
// POST /shot {"url": "https://…"} with `Authorization: Bearer $SHOT_TOKEN`
// answers a 1200×750 JPEG of the page's first screen. One page renders at a
// time; a few more wait in line and the rest get 503. The Sprite's network
// policy blocks private addresses on the way out; loopback stays inside the
// VM, so every request the page makes is checked here as well.
import { createServer } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { lookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import { chromium } from "playwright-core";

const PORT = Number(process.env.PORT || 8080);
const TOKEN = process.env.SHOT_TOKEN || "";
const WIDTH = 1200;
const HEIGHT = 750;
const NAV_TIMEOUT = 20_000;
const SETTLE_MS = 1_200;
const MAX_WAITING = 4;
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";

// Common consent banners and overlays, hidden before the capture.
const HIDE_CSS = `
#onetrust-consent-sdk, #onetrust-banner-sdk, #CybotCookiebotDialog, #usercentrics-root,
.qc-cmp2-container, .fc-consent-root, #didomi-host, .didomi-popup, #truste-consent-track,
.cc-window, .cookie-banner, .cookie-consent, .cookies-banner, #cookie-banner, #cookie-notice,
#cookie-law-info-bar, .cmplz-cookiebanner, #gdpr-cookie-message, .osano-cm-window,
[id*="cookie-banner" i], [class*="cookie-banner" i], [id*="consent-banner" i], [class*="consent-banner" i],
[aria-label*="cookie" i][role="dialog"], [aria-label*="consent" i][role="dialog"]
{ display: none !important; visibility: hidden !important; }
html, body { overflow: auto !important; }
`;

// Banners the selectors miss: fixed or sticky boxes that talk about cookies,
// privacy or consent and cover less than half of the screen.
function hideConsentOverlays() {
  const words = /cookie|consent|privacy|gdpr|privacidade|consentimento|lgpd/i;
  for (const el of document.querySelectorAll("body *")) {
    const style = getComputedStyle(el);
    if (style.position !== "fixed" && style.position !== "sticky") continue;
    const box = el.getBoundingClientRect();
    if (box.height === 0 || box.height > innerHeight / 2) continue;
    if (words.test(el.textContent || "")) el.style.setProperty("display", "none", "important");
  }
}

if (TOKEN.length < 32) {
  console.error("SHOT_TOKEN must be set (at least 32 characters)");
  process.exit(1);
}

const internal = new BlockList();
for (const [net, prefix] of [["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8],
  ["169.254.0.0", 16], ["172.16.0.0", 12], ["192.168.0.0", 16], ["224.0.0.0", 3]]) {
  internal.addSubnet(net, prefix, "ipv4");
}
for (const [net, prefix] of [["::", 127], ["fc00::", 7], ["fe80::", 10], ["ff00::", 8]]) {
  internal.addSubnet(net, prefix, "ipv6");
}

const verdicts = new Map();

function internalAddress(address) {
  const mapped = address.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/i);
  if (mapped) return internal.check(mapped[1], "ipv4");
  return internal.check(address, isIP(address) === 6 ? "ipv6" : "ipv4");
}

// True when the host is, or resolves to, an internal address. Answers are
// kept for the life of the process; unresolvable hosts are left to fail.
async function blockedHost(host) {
  const bare = host.replace(/^\[|\]$/g, "");
  if (isIP(bare)) return internalAddress(bare);
  if (bare === "localhost" || bare.endsWith(".localhost")) return true;
  if (!verdicts.has(bare)) {
    const verdict = lookup(bare, { all: true })
      .then((addresses) => addresses.some(({ address }) => internalAddress(address)))
      .catch(() => false);
    verdicts.set(bare, verdict);
  }
  return verdicts.get(bare);
}

let browser = null;
let queue = Promise.resolve();
let waiting = 0;

async function getBrowser() {
  if (browser?.isConnected()) return browser;
  browser = await chromium.launch({ args: ["--disable-dev-shm-usage", "--mute-audio"] });
  browser.on("disconnected", () => (browser = null));
  return browser;
}

function authorized(req) {
  const given = Buffer.from((req.headers.authorization || "").replace(/^Bearer /, ""));
  const expected = Buffer.from(TOKEN);
  return given.length === expected.length && timingSafeEqual(given, expected);
}

function parseTarget(raw) {
  try {
    const url = new URL(raw);
    return ["http:", "https:"].includes(url.protocol) ? url : null;
  } catch {
    return null;
  }
}

async function capture(url) {
  const context = await (await getBrowser()).newContext({
    viewport: { width: WIDTH, height: HEIGHT },
    userAgent: USER_AGENT,
    locale: "pt-BR",
    acceptDownloads: false,
    serviceWorkers: "block",
  });

  try {
    await context.route("**/*", async (route) => {
      const { protocol, hostname } = new URL(route.request().url());
      const web = protocol === "http:" || protocol === "https:";
      if (web && (await blockedHost(hostname))) return route.abort("blockedbyclient");
      return route.continue();
    });

    const page = await context.newPage();
    // Only the page itself may navigate; popups are closed at once.
    context.on("page", (other) => other !== page && other.close().catch(() => {}));

    let response = null;
    try {
      response = await page.goto(url.href, { waitUntil: "load", timeout: NAV_TIMEOUT });
    } catch (error) {
      // A slow page that never fires `load` is still worth a capture, if
      // something got painted.
      if (!/Timeout/.test(error.message)) throw error;
    }

    if (response && response.status() >= 400) {
      return { status: 422, error: `page answered ${response.status()}` };
    }

    await page.addStyleTag({ content: HIDE_CSS }).catch(() => {});
    await page.evaluate(hideConsentOverlays).catch(() => {});
    await page.waitForTimeout(SETTLE_MS);
    const image = await page.screenshot({ type: "jpeg", quality: 82, timeout: 10_000 });
    return { status: 200, image };
  } finally {
    await context.close().catch(() => {});
  }
}

function send(res, status, body, type = "application/json") {
  res.writeHead(status, { "content-type": type, "cache-control": "no-store" });
  res.end(type === "application/json" ? JSON.stringify(body) : body);
}

function readJson(req) {
  return new Promise((resolve) => {
    let size = 0;
    const chunks = [];
    req.on("data", (chunk) => {
      size += chunk.length;
      if (size > 4096) req.destroy();
      else chunks.push(chunk);
    });
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      } catch {
        resolve(null);
      }
    });
    req.on("error", () => resolve(null));
  });
}

createServer(async (req, res) => {
  if (req.method === "GET" && req.url === "/health") return send(res, 200, { ok: true });
  if (req.method !== "POST" || req.url !== "/shot") return send(res, 404, { error: "not found" });
  if (!authorized(req)) return send(res, 401, { error: "unauthorized" });

  const body = await readJson(req);
  const url = parseTarget(body?.url);
  if (!url) return send(res, 400, { error: "url must be http or https" });
  if (waiting >= MAX_WAITING) return send(res, 503, { error: "busy" });

  waiting += 1;
  const job = queue.then(() => capture(url));
  queue = job.catch(() => {});

  try {
    const result = await job;
    if (result.image) send(res, 200, result.image, "image/jpeg");
    else send(res, result.status, { error: result.error });
  } catch (error) {
    send(res, 422, { error: error.message.split("\n")[0].slice(0, 200) });
  } finally {
    waiting -= 1;
  }
}).listen(PORT, () => console.log(`screenshots listening on ${PORT}`));
