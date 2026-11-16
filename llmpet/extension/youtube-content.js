(() => {
  window.__notchboxYouTube?.dispose();
  const lifecycle = new AbortController();
  let videoEvents = new AbortController();
  let video = null;
  let metadataVideoID = null;
  let buffering = false;
  let lastReportAt = 0;
  let lastPayload = "";

  function videoID() {
    const url = new URL(location.href);
    if (url.pathname !== "/watch") return null;
    const id = url.searchParams.get("v");
    return /^[a-zA-Z0-9_-]{11}$/.test(id || "") ? id : null;
  }

  function availableButton(selector) {
    const button = document.querySelector(selector);
    return button && !button.disabled && button.getAttribute("aria-disabled") !== "true"
      && button.getClientRects().length > 0 ? button : null;
  }

  function snapshot() {
    const id = videoID();
    if (!id || !video || !video.isConnected || video.readyState < 1 || metadataVideoID !== id) return null;
    const player = document.querySelector("#movie_player");
    const ad = player?.classList.contains("ad-showing") || false;
    const liveBadge = document.querySelector(".ytp-live-badge");
    const isLive = !ad && (video.duration === Infinity || Boolean(liveBadge?.getClientRects().length));
    const title = document.querySelector("ytd-watch-metadata h1")?.textContent?.trim()
      || document.querySelector('meta[property="og:title"]')?.content
      || document.title.replace(/\s*-\s*YouTube$/, "").trim();
    if (!title) return null;
    const artist = document.querySelector("ytd-watch-metadata #owner #channel-name a")?.textContent?.trim()
      || document.querySelector("#owner #channel-name a")?.textContent?.trim() || "YouTube";
    const duration = !ad && !isLive && Number.isFinite(video.duration) ? Math.max(0, video.duration) : 0;
    return {
      videoID: id,
      title: title.slice(0, 1000),
      artist: artist.slice(0, 300),
      duration,
      position: !ad && Number.isFinite(video.currentTime) ? Math.max(0, video.currentTime) : 0,
      playbackRate: Number.isFinite(video.playbackRate) ? video.playbackRate : 1,
      isPlaying: !video.paused && !video.ended && !video.error,
      isLive,
      isBuffering: buffering || video.seeking || video.readyState < 3,
      canSeek: !ad && !isLive && duration > 0 && video.seekable.length > 0,
      canGoPrevious: !ad && Boolean(availableButton(".ytp-prev-button")),
      canGoNext: !ad && Boolean(availableButton(".ytp-next-button")),
    };
  }

  function report(force = false) {
    const now = Date.now();
    if (!force && now - lastReportAt < 2000) return;
    const media = snapshot();
    const payload = JSON.stringify(media);
    if (!force && payload === lastPayload && now - lastReportAt < 5000) return;
    lastReportAt = now;
    lastPayload = payload;
    try {
      chrome.runtime.sendMessage({ type: "notchbox-media-state", media }).catch(() => {});
    } catch {
      lifecycle.abort();
      videoEvents.abort();
      clearInterval(timer);
    }
  }

  function bind() {
    const next = document.querySelector("video.html5-main-video");
    if (next === video) return;
    videoEvents.abort();
    videoEvents = new AbortController();
    video = next;
    metadataVideoID = video?.readyState >= 1 ? videoID() : null;
    buffering = false;
    if (video) {
      for (const name of ["play", "pause", "ended", "ratechange", "durationchange", "seeked", "seeking", "emptied", "error"]) {
        video.addEventListener(name, () => report(true), { signal: videoEvents.signal });
      }
      video.addEventListener("loadedmetadata", () => {
        metadataVideoID = videoID();
        buffering = false;
        report(true);
      }, { signal: videoEvents.signal });
      video.addEventListener("waiting", () => { buffering = true; report(true); }, { signal: videoEvents.signal });
      video.addEventListener("playing", () => { buffering = false; report(true); }, { signal: videoEvents.signal });
      video.addEventListener("timeupdate", () => report(), { signal: videoEvents.signal });
    }
    report(true);
  }

  async function execute(message) {
    const current = snapshot();
    if (!current || message.videoID !== current.videoID) return false;
    switch (message.action) {
      case "playPause":
        if (video.paused || video.ended) await video.play();
        else video.pause();
        return true;
      case "seek":
        if (!current.canSeek || !Number.isFinite(message.position)
          || message.position < 0 || message.position > current.duration) return false;
        video.currentTime = message.position;
        return true;
      case "previous": {
        const button = current.canGoPrevious && availableButton(".ytp-prev-button");
        if (!button) return false;
        button.click();
        return true;
      }
      case "next": {
        const button = current.canGoNext && availableButton(".ytp-next-button");
        if (!button) return false;
        button.click();
        return true;
      }
      default: return false;
    }
  }

  function onMessage(message, _sender, respond) {
    if (message?.type === "notchbox-media-snapshot") {
      bind();
      respond({ media: snapshot() });
      return false;
    }
    if (message?.type !== "notchbox-media-command") return false;
    execute(message).then(success => { report(true); respond({ success }); })
      .catch(() => { report(true); respond({ success: false }); });
    return true;
  }

  chrome.runtime.onMessage.addListener(onMessage);
  document.addEventListener("yt-navigate-start", () => {
    metadataVideoID = null;
    report(true);
  }, { signal: lifecycle.signal });
  document.addEventListener("yt-navigate-finish", () => { bind(); report(true); }, { signal: lifecycle.signal });
  document.addEventListener("visibilitychange", () => report(true), { signal: lifecycle.signal });
  window.addEventListener("pagehide", () => {
    try { chrome.runtime.sendMessage({ type: "notchbox-media-state", media: null }).catch(() => {}); } catch {}
  }, { signal: lifecycle.signal });
  const timer = setInterval(() => { bind(); report(); }, 5000);
  window.__notchboxYouTube = {
    dispose() {
      lifecycle.abort();
      videoEvents.abort();
      clearInterval(timer);
      chrome.runtime.onMessage.removeListener(onMessage);
    },
  };
  bind();
})();
