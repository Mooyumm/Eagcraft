const extensionAPI = globalThis.browser ?? globalThis.chrome;

const appBridgeOrigin = "http://127.0.0.1:49158";
const appBridgeToken = "inspiration-library-safari-extension-v1";

const postMessageToApp = (message) => fetch(`${appBridgeOrigin}/drag`, {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Inspiration-Bridge": appBridgeToken
  },
  body: JSON.stringify(message)
}).then((response) => response.ok);

const prefetchImageForApp = async (message) => {
  if (!message?.sessionID || !/^https?:/i.test(message.imageURL || "")) return false;
  const response = await fetch(message.imageURL, {
    credentials: "include",
    cache: "force-cache",
    referrer: message.sourceURL || undefined,
    referrerPolicy: "strict-origin-when-cross-origin"
  });
  if (!response.ok) throw new Error(`image fetch failed: ${response.status}`);

  const declaredSize = Number(response.headers.get("content-length") || 0);
  if (declaredSize > 80 * 1024 * 1024) throw new Error("image exceeds 80 MB");
  const payload = await response.arrayBuffer();
  if (!payload.byteLength || payload.byteLength > 80 * 1024 * 1024) throw new Error("invalid image payload size");

  const delivered = await fetch(`${appBridgeOrigin}/payload`, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Inspiration-Bridge": appBridgeToken,
      "X-Inspiration-Session": message.sessionID,
      "X-Inspiration-Mime": response.headers.get("content-type") || "application/octet-stream"
    },
    body: payload
  });
  return delivered.ok;
};

extensionAPI.runtime.onMessage.addListener((message) => {
  if (!["imageDragStarted", "imageDragEnded", "imageDragDropped"].includes(message?.type)) return;
  return postMessageToApp(message)
    .then(async (ok) => {
      const payloadReady = ok && message.type === "imageDragStarted"
        ? await prefetchImageForApp(message).catch(() => false)
        : false;
      return { ok, payloadReady };
    })
    .catch((error) => ({ ok: false, error: String(error) }));
});
