"use client";

import { useEffect, useMemo, useState } from "react";
import { useParams } from "next/navigation";
import { decryptBlob } from "@/lib/wasm/zend";

export default function DownloadPage() {
  const params = useParams<{ id: string }>();
  const id = params.id;

  return <DownloadClient id={id} />;
}

function DownloadClient({ id }: { id: string }) {
  const relayUrl = process.env.NEXT_PUBLIC_RELAY_URL;
  const [isDownloading, setIsDownloading] = useState(false);
  const [isComplete, setIsComplete] = useState(false);
  const [error, setError] = useState("");
  const [hasFragmentKey, setHasFragmentKey] = useState(false);

  useEffect(() => {
    setHasFragmentKey(Boolean(window.location.hash));
  }, []);

  const downloadUrl = useMemo(() => {
    if (!relayUrl) return "";
    return `${relayUrl}/download/${id}`;
  }, [relayUrl, id]);

  const status = useMemo(() => {
    if (error) return "error";
    if (isComplete) return "done";
    if (isDownloading) return "decrypting";
    return "idle";
  }, [error, isComplete, isDownloading]);

  async function handleDownload() {
    if (!relayUrl) {
      setError("NEXT_PUBLIC_RELAY_URL is missing.");
      return;
    }

    const keyB64 = window.location.hash.slice(1);
    if (!keyB64) {
      setError("Missing decryption key in URL fragment.");
      return;
    }

    console.log("[download-page] id", id);
    console.log("[download-page] fragment key", keyB64);
    console.log("[download-page] relay url", relayUrl);
    console.log("[download-page] download url", downloadUrl);

    try {
      setError("");
      setIsComplete(false);
      setIsDownloading(true);

      const response = await fetch(downloadUrl);
      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Download failed with ${response.status}`);
      }

      const encryptedBlob = await response.arrayBuffer();
      console.log("[download-page] ciphertext bytes", encryptedBlob.byteLength);

      const { filename, fileBytes } = await decryptBlob(encryptedBlob, keyB64);

      console.log("[download-page] decrypt result", {
        filename,
        plaintextBytes: fileBytes.length,
      });

      const objectUrl = window.URL.createObjectURL(new Blob([fileBytes]));
      const a = document.createElement("a");
      a.href = objectUrl;
      a.download = filename || `zend-${id}`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      window.URL.revokeObjectURL(objectUrl);

      setIsComplete(true);
    } catch (err) {
      console.error("[download-page] download error", err);
      setError(err instanceof Error ? err.message : "Download failed.");
    } finally {
      setIsDownloading(false);
    }
  }

  return (
    <main className="page-shell">
      <div className="page-wrap">
        <header className="header">
          <span className="header-path">zend</span>
          <span className="header-dot" data-status={status} />
        </header>

        <div className="transfer-box">
          <div className="transfer-id">
            <span className="transfer-label">transfer</span>
            <span className="transfer-value">{id}</span>
          </div>
          <div className="transfer-checks">
            <span className={hasFragmentKey ? "" : "check-missing"}>
              key: {hasFragmentKey ? "present" : "missing"}
            </span>
            <span className="separator">·</span>
            <span>single-use</span>
          </div>
        </div>

        <div className="actions">
          <button
            className="button button-primary"
            onClick={handleDownload}
            disabled={isDownloading || isComplete}
            style={{ flex: 1 }}
          >
            {isComplete
              ? "download complete"
              : isDownloading
                ? "decrypting..."
                : "download & decrypt"}
          </button>
        </div>

        {error && <div className="notice notice-error">{error}</div>}

        {isComplete && (
          <div className="result">
            <div className="result-label">complete</div>
            <div className="result-meta">
              <span>file saved to downloads</span>
              <span className="separator">·</span>
              <span>relay copy consumed</span>
            </div>
          </div>
        )}

        <footer className="footer">
          <span>decrypted client-side</span>
          <span className="separator">·</span>
          <span>relay sees ciphertext only</span>
          <span className="separator">·</span>
          <span>key never leaves your browser</span>
        </footer>
      </div>
    </main>
  );
}
