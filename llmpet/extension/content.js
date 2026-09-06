// Guard + block scope. This file is injected two ways — declaratively on a fresh
// page load, and programmatically by the background after an extension reload —
// so it must tolerate running twice. Without the IIFE the second injection dies
// on a top-level const redeclaration; without the flag it would run two loops.
if (!window.__llmpetActive) {
  window.__llmpetActive = true;

  // Detecting "the model is answering" has to survive both UI redesigns and UI
  // language. Two independent signals, OR'd:
  //
  //  1. A visible stop/cancel control. data-testid stays English, but aria-label
  //     is localised — matching only /stop/i missed a Spanish UI entirely.
  //  2. Sustained DOM churn. Streaming tokens rewrite text nodes many times a
  //     second; an idle page barely mutates. This one is language-independent and
  //     survives markup changes, which is why it carries the most weight.

  const STOP_HINT = /stop|cancel|detener|parar|cancelar|arrêter|abbrechen|interromper/i;

  const hasStopControl = () =>
    [...document.querySelectorAll("button,[role=button]")].some((b) => {
      const hint = `${b.getAttribute("aria-label") || ""} ${b.dataset?.testid || ""}`;
      return STOP_HINT.test(hint) && b.offsetParent !== null;
    });

  const SITE = {
    "claude.ai": "Claude",
    "chatgpt.com": "ChatGPT",
    "chat.openai.com": "ChatGPT",
    "gemini.google.com": "Gemini",
    "aistudio.google.com": "AI Studio",
  }[location.hostname] || location.hostname;

  // Churn well above idle noise but below what one streaming response produces.
  const CHURN_THRESHOLD = 20;
  const HEARTBEAT_MS = 4 * 60 * 1000;

  let churn = 0;
  let state = "seen";
  let reported = null;
  let reportedAt = 0;
  let wasBusy = false;
  let activeSince = null;

  const observer = new MutationObserver((records) => { churn += records.length; });
  observer.observe(document.body, { subtree: true, childList: true, characterData: true });

  let timer = null;

  // Reloading the extension orphans the content scripts already running in open
  // tabs: chrome.runtime is gone and every sendMessage throws "Extension context
  // invalidated". Detect it and shut this instance down quietly — the freshly
  // injected script in the reloaded tab takes over, and meanwhile the background
  // sweep still lists the tab.
  function isAttached() {
    try {
      return Boolean(chrome.runtime && chrome.runtime.id);
    } catch {
      return false;
    }
  }

  function teardown() {
    // Release the flag so a later re-injection can take this tab over.
    window.__llmpetActive = false;
    if (timer !== null) clearInterval(timer);
    timer = null;
    observer.disconnect();
    document.removeEventListener("visibilitychange", tick);
  }

  function send() {
    if (!isAttached()) return teardown();

    const now = Date.now();
    if (state === reported && now - reportedAt < HEARTBEAT_MS) return;
    reported = state;
    reportedAt = now;

    post({
      state,
      title: document.title.replace(/\s*[-–|]\s*(Claude|ChatGPT|Gemini).*$/i, "").trim()
        || "Sin título",
      context: SITE,
      origin: "web",
      agent: SITE,
      activeSince: activeSince ? activeSince / 1000 : null,
      source: "chrome",
      open: location.href,
    });
  }

  // Passing a callback makes sendMessage use the callback protocol instead of
  // returning a Promise, so there is no rejection to leak as "Uncaught Error".
  // Failures arrive in chrome.runtime.lastError, and merely *reading* that
  // property is what marks them handled.
  function post(message) {
    try {
      chrome.runtime.sendMessage(message, () => {
        const failure = chrome.runtime.lastError;
        // A sleeping service worker fails here too; only a dead context is fatal,
        // otherwise one blip would silence this tab until a manual reload.
        if (failure && !isAttached()) teardown();
      });
    } catch {
      teardown();
    }
  }

  function tick() {
    const busy = hasStopControl() || churn >= CHURN_THRESHOLD;
    churn = 0;

    if (busy) {
      if (!wasBusy) activeSince = Date.now();
      state = "working";
    } else if (wasBusy) {
      state = document.hidden ? "ready" : "seen";
      activeSince = null;
    } else if (state === "ready" && !document.hidden) {
      state = "seen";
    }
    wasBusy = busy;
    send();
  }

  // Safety net: anything inside Chrome's own extension plumbing that still rejects
  // after the context dies is this script's problem to absorb, not the page's to
  // display. Only swallow that specific error so real bugs stay visible.
  window.addEventListener("unhandledrejection", (event) => {
    if (/Extension context invalidated|Receiving end does not exist/i
        .test(String(event.reason?.message || event.reason))) {
      event.preventDefault();
      teardown();
    }
  });

  document.addEventListener("visibilitychange", tick);
  window.addEventListener("pagehide", () => {
    if (isAttached()) post({ state: "gone" });
  });

  timer = setInterval(tick, 1000);
  tick();

}
