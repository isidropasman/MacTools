(() => {
  const ENDPOINT = "ws://127.0.0.1:7718";
  const PROTOCOL = "notchbox-media-v1";
  const MATCHES = ["https://www.youtube.com/*", "https://youtube.com/*", "https://m.youtube.com/*"];
  let socket = null;
  let reconnectTimer = null;
  let reconnectDelay = 1000;
  let refreshing = false;
  const knownTabs = new Set();

  function videoID(url) {
    try {
      const parsed = new URL(url);
      if (parsed.protocol !== "https:" || !["www.youtube.com", "youtube.com", "m.youtube.com"].includes(parsed.hostname)
        || parsed.pathname !== "/watch") return null;
      const id = parsed.searchParams.get("v");
      return /^[a-zA-Z0-9_-]{11}$/.test(id || "") ? id : null;
    } catch { return null; }
  }

  function send(message) {
    if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
  }

  function update(tab, media) {
    const id = videoID(tab.url);
    if (id && media?.videoID === id) {
      knownTabs.add(tab.id);
      send({ kind: "state", tabID: tab.id, media });
    } else {
      knownTabs.delete(tab.id);
      send({ kind: "gone", tabID: tab.id });
    }
  }

  async function readTab(tab) {
    if (!videoID(tab.url)) { update(tab, null); return; }
    try {
      let result;
      try {
        result = await chrome.tabs.sendMessage(tab.id, { type: "notchbox-media-snapshot" }, { frameId: 0 });
      } catch {
        await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["youtube-content.js"] });
        result = await chrome.tabs.sendMessage(tab.id, { type: "notchbox-media-snapshot" }, { frameId: 0 });
      }
      // Navigation can replace a video while the content script is answering.
      const currentTab = await chrome.tabs.get(tab.id);
      update(currentTab, videoID(currentTab.url) === videoID(tab.url) ? result?.media : null);
    } catch { update(tab, null); }
  }

  async function refresh() {
    if (refreshing) return;
    refreshing = true;
    try {
      const tabs = await chrome.tabs.query({ url: MATCHES });
      const live = new Set(tabs.map(tab => tab.id));
      for (const id of knownTabs) {
        if (!live.has(id)) { knownTabs.delete(id); send({ kind: "gone", tabID: id }); }
      }
      await Promise.allSettled(tabs.map(readTab));
    } finally { refreshing = false; }
  }

  async function execute(command) {
    if (command?.kind !== "command" || !Number.isInteger(command.tabID)) return;
    try {
      const tab = await chrome.tabs.get(command.tabID);
      if (!command.videoID || videoID(tab.url) !== command.videoID) return;
      if (command.action === "focus") {
        await chrome.tabs.update(tab.id, { active: true });
        await chrome.windows.update(tab.windowId, { focused: true });
      } else {
        await chrome.tabs.sendMessage(tab.id, {
          type: "notchbox-media-command", videoID: command.videoID,
          action: command.action, position: command.position,
        }, { frameId: 0 });
      }
      await readTab(tab);
    } catch {
      knownTabs.delete(command.tabID);
      send({ kind: "gone", tabID: command.tabID });
    }
  }

  function connect() {
    if (socket && [WebSocket.OPEN, WebSocket.CONNECTING].includes(socket.readyState)) return;
    clearTimeout(reconnectTimer);
    socket = new WebSocket(ENDPOINT, PROTOCOL);
    const current = socket;
    current.onopen = () => { reconnectDelay = 1000; refresh().catch(() => {}); };
    current.onmessage = event => {
      try { execute(JSON.parse(event.data)).catch(() => {}); } catch {}
    };
    current.onclose = () => {
      if (socket !== current) return;
      socket = null;
      reconnectTimer = setTimeout(connect, reconnectDelay);
      reconnectDelay = Math.min(reconnectDelay * 2, 30000);
    };
    current.onerror = () => current.close();
  }

  chrome.runtime.onMessage.addListener((message, sender) => {
    if (message?.type !== "notchbox-media-state" || !sender.tab || sender.frameId !== 0) return;
    if (!videoID(sender.tab.url) && message.media !== null) return;
    update(sender.tab, message.media);
    connect();
  });
  chrome.tabs.onRemoved.addListener(tabID => {
    knownTabs.delete(tabID);
    send({ kind: "gone", tabID });
  });
  chrome.tabs.onUpdated.addListener((tabID, change, tab) => {
    if (change.url && !videoID(change.url)) {
      knownTabs.delete(tabID);
      send({ kind: "gone", tabID });
    }
    if (change.status === "complete" && videoID(tab.url)) readTab(tab).catch(() => {});
  });
  chrome.runtime.onStartup.addListener(() => { connect(); refresh().catch(() => {}); });
  chrome.runtime.onInstalled.addListener(() => { connect(); refresh().catch(() => {}); });
  setInterval(() => {
    connect();
    refresh().catch(() => {});
  }, 5000);
  // Chrome 116+ keeps the worker alive when WebSocket traffic occurs within 30 seconds.
  setInterval(() => send({ kind: "ping" }), 20000);
  connect();
  refresh().catch(() => {});
})();
