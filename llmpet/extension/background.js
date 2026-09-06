const ENDPOINT = "http://127.0.0.1:7717/session";

const SITES = {
  "claude.ai": "Claude",
  "chatgpt.com": "ChatGPT",
  "chat.openai.com": "ChatGPT",
  "gemini.google.com": "Gemini",
  "aistudio.google.com": "AI Studio",
};

const MATCHES = Object.keys(SITES).map((h) => `https://${h}/*`);

// The app resolves this to /Applications/<name>.app to draw the real browser icon.
const BROWSER = (() => {
  const ua = navigator.userAgent;
  if (/Arc\//.test(ua)) return "Arc";
  if (/Edg\//.test(ua)) return "Microsoft Edge";
  if (/OPR\//.test(ua)) return "Opera";
  return "Google Chrome";
})();

function post(payload) {
  // text/plain keeps this a CORS "simple request", so Chrome skips the preflight
  // entirely. The listener parses the body as JSON regardless of the header, and
  // a failed preflight was silently dropping every report.
  fetch(ENDPOINT, {
    method: "POST",
    headers: { "content-type": "text/plain" },
    body: JSON.stringify(payload),
  }).catch((e) => console.warn("[LLMPet] no pude reportar:", e.message));
}

function clean(title) {
  return title.replace(/\s*[-–|]\s*(Claude|ChatGPT|Gemini).*$/i, "").trim() || "Sin título";
}

// States reported by content scripts, keyed by tab id. A tab with no content
// script (injection failed, page loaded before install) still gets listed by the
// sweep below as "seen" — being visible matters more than being precise.
const reported = new Map();

async function sweep() {
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({ url: MATCHES });
  } catch (e) {
    console.warn("[LLMPet] tabs.query falló:", e.message);
    return;
  }
  const live = new Set();
  for (const tab of tabs) {
    live.add(tab.id);
    const host = new URL(tab.url).hostname;
    // Merge over whatever the content script last said, so the 5s sweep refreshes
    // the heartbeat without flattening a live "working" back to "seen".
    post({
      ...(reported.get(tab.id) || { state: "seen" }),
      key: `chrome-${tab.id}`,
      tabId: tab.id,
      title: clean(tab.title || ""),
      context: SITES[host] || host,
      source: "chrome",
      open: tab.url,
      browser: BROWSER,
      favicon: tab.favIconUrl || null,
    });
  }
  for (const id of reported.keys()) {
    if (!live.has(id)) reported.delete(id);
  }
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!sender.tab) return;
  reported.set(sender.tab.id, msg);
  post({
    ...msg,
    key: `chrome-${sender.tab.id}`,
    tabId: sender.tab.id,
    browser: BROWSER,
    favicon: sender.tab.favIconUrl || null,
  });
});

chrome.tabs.onRemoved.addListener((tabId) => {
  reported.delete(tabId);
  post({ key: `chrome-${tabId}`, state: "gone" });
});

// chrome.alarms would need another permission; the service worker is kept alive
// by these events often enough in practice, and sweep() is idempotent.
// Reloading the extension leaves the content scripts in already-open tabs
// orphaned, and Chrome does not re-inject them. Doing it explicitly is what
// makes "reload the extension" enough, instead of also reloading every tab.
async function inject() {
  let tabs = [];
  try {
    tabs = await chrome.tabs.query({ url: MATCHES });
  } catch {
    return;
  }
  for (const tab of tabs) {
    chrome.scripting
      .executeScript({ target: { tabId: tab.id }, files: ["content.js"] })
      .catch(() => {});  // pages Chrome refuses to script are not worth reporting
  }
}

chrome.runtime.onStartup.addListener(() => { inject(); sweep(); });
chrome.runtime.onInstalled.addListener(() => { inject(); sweep(); });
inject();
chrome.tabs.onUpdated.addListener(sweep);
chrome.tabs.onActivated.addListener(sweep);
sweep();
setInterval(sweep, 5000);
