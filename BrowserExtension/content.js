(() => {
  const extensionAPI = globalThis.browser ?? globalThis.chrome;
  let activeSessionID = null;

  const firstURLFromSrcset = (srcset) => {
    if (!srcset) return "";
    const candidates = srcset.split(",").map((entry) => entry.trim().split(/\s+/)[0]).filter(Boolean);
    return candidates.at(-1) || "";
  };

  const backgroundURL = (element) => {
    let current = element;
    for (let depth = 0; current && depth < 5; depth += 1, current = current.parentElement) {
      const value = getComputedStyle(current).backgroundImage || "";
      const match = value.match(/url\(["']?(.*?)["']?\)/);
      if (match?.[1]) return match[1];
    }
    return "";
  };

  const suggestedName = (image, absoluteURL) => {
    const explicit = image?.alt || image?.getAttribute("title") || image?.getAttribute("aria-label");
    if (explicit?.trim()) return explicit.trim();
    try {
      const filename = decodeURIComponent(new URL(absoluteURL).pathname.split("/").filter(Boolean).at(-1) || "");
      if (filename) return filename.replace(/\.[a-z0-9]{2,5}$/i, "");
    } catch (_) {}
    return document.title || "网页图片";
  };

  const imageMetadata = (target) => {
    const element = target instanceof Element ? target : null;
    if (!element) return null;

    const image = element.closest("img") || element.querySelector?.("img");
    const source = image?.currentSrc
      || image?.src
      || image?.getAttribute("data-src")
      || image?.getAttribute("data-original")
      || firstURLFromSrcset(image?.getAttribute("data-srcset") || image?.srcset)
      || backgroundURL(element)
      || "";
    if (!source) return null;

    let absoluteURL;
    try { absoluteURL = new URL(source, document.baseURI).href; }
    catch (_) { return null; }

    const sessionID = globalThis.crypto?.randomUUID?.()
      || `${Date.now()}-${Math.random().toString(36).slice(2)}`;

    return {
      type: "imageDragStarted",
      imageURL: absoluteURL,
      sourceURL: location.href,
      pageTitle: document.title || "网页图片",
      suggestedName: suggestedName(image, absoluteURL),
      width: image?.naturalWidth || 0,
      height: image?.naturalHeight || 0,
      sessionID,
      timestamp: Date.now(),
      cursorScreenX: 0,
      cursorScreenY: 0
    };
  };

  document.addEventListener("dragstart", (event) => {
    const metadata = imageMetadata(event.target);
    if (!metadata) return;
    metadata.cursorScreenX = event.screenX;
    metadata.cursorScreenY = event.screenY;
    activeSessionID = metadata.sessionID;

    try { if (event.dataTransfer) event.dataTransfer.effectAllowed = "copy"; } catch (_) {}
    // Safari normally publishes an image drag as a navigable URL as well as an
    // image. Remove those URL/text flavors so a long hover or a slightly missed
    // drop cannot navigate the source tab. The private metadata plus the
    // background-prefetched payload are sufficient for native collection.
    try { event.dataTransfer?.clearData("text/uri-list"); } catch (_) {}
    try { event.dataTransfer?.clearData("text/plain"); } catch (_) {}
    try { event.dataTransfer?.setData("application/x-eagle-replica", JSON.stringify(metadata)); } catch (_) {}

    Promise.resolve(extensionAPI.runtime.sendMessage(metadata)).catch(() => {});
  }, true);

  document.addEventListener("dragend", () => {
    if (!activeSessionID) return;
    const sessionID = activeSessionID;
    activeSessionID = null;
    Promise.resolve(extensionAPI.runtime.sendMessage({ type: "imageDragEnded", sessionID, timestamp: Date.now() })).catch(() => {});
  }, true);

  // The browser-triggered collector is a click-through overlay so Safari stays
  // frontmost even during a long hover. Prevent the underlying webpage from
  // treating the eventual release as a navigation, upload, or page-local drop.
  document.addEventListener("dragover", (event) => {
    if (activeSessionID) event.preventDefault();
  }, true);

  document.addEventListener("drop", (event) => {
    if (!activeSessionID) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    // A genuine drop is distinct from dragend (which also fires on Escape).
    // Supply an independent commit signal when macOS misses global mouse-up.
    Promise.resolve(extensionAPI.runtime.sendMessage({
      type: "imageDragDropped",
      sessionID: activeSessionID,
      timestamp: Date.now()
    })).catch(() => {});
  }, true);
})();
