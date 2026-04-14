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

  const activeStage = error ? 0 : isComplete ? 4 : isDownloading ? 3 : 1;

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
      const { filename, fileBytes } = await decryptBlob(encryptedBlob, keyB64);

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
      setError(err instanceof Error ? err.message : "Download failed.");
    } finally {
      setIsDownloading(false);
    }
  }

  function stageClass(index: number) {
    if (error && index >= 2) return "stage-error";
    if (isComplete && index <= 3) return "stage-done";
    if (isDownloading && index < activeStage) return "stage-done";
    if (isDownloading && index === activeStage) return "stage-active";
    if (!isDownloading && !isComplete && index === 1) return "stage-active";
    return "stage-idle";
  }

  function stageText(index: number) {
    if (error && index >= 2) return "fault";
    if (isComplete && index <= 3) return "done";
    if (isDownloading && index < activeStage) return "done";
    if (isDownloading && index === activeStage) return "live";
    if (!isDownloading && !isComplete && index === 1) return "ready";
    return "idle";
  }

  return (
    <main className="page-shell">
      <div className="page-wrap">
        <section className="session-header">
          <div className="session-top">
            <div className="session-title">
              <span className="session-chip">zend://retrieval capsule</span>
              <h1>payload restoration console</h1>
            </div>
            <div className="session-status">
              {isComplete
                ? "payload restored"
                : isDownloading
                  ? "restoring"
                  : "awaiting retrieval"}
            </div>
          </div>

          <div className="session-grid">
            <div className="session-stat">
              <div className="session-stat-label">transfer_id</div>
              <div className="session-stat-value">{id}</div>
            </div>
            <div className="session-stat">
              <div className="session-stat-label">key_source</div>
              <div className="session-stat-value">url_fragment</div>
            </div>
            <div className="session-stat">
              <div className="session-stat-label">relay_mode</div>
              <div className="session-stat-value">single serve</div>
            </div>
            <div className="session-stat">
              <div className="session-stat-label">target</div>
              <div className="session-stat-value">{relayUrl ?? "unset"}</div>
            </div>
          </div>
        </section>

        <section className="panel-grid">
          <div className="panel">
            <div className="panel-header">
              <div className="panel-title">retrieval pipeline</div>
              <div className="muted">local restoration path</div>
            </div>

            <div className="panel-body stack">
              <div className="pipeline">
                <div className="stage-row">
                  <div className="stage-index">[01]</div>
                  <div className="stage-name">receive ciphertext</div>
                  <div className={`stage-state ${stageClass(1)}`}>
                    {stageText(1)}
                  </div>
                </div>
                <div className="stage-row">
                  <div className="stage-index">[02]</div>
                  <div className="stage-name">validate capsule</div>
                  <div className={`stage-state ${stageClass(2)}`}>
                    {stageText(2)}
                  </div>
                </div>
                <div className="stage-row">
                  <div className="stage-index">[03]</div>
                  <div className="stage-name">restore payload locally</div>
                  <div className={`stage-state ${stageClass(3)}`}>
                    {stageText(3)}
                  </div>
                </div>
              </div>

              <div className="actions">
                <button
                  className="button"
                  onClick={handleDownload}
                  disabled={isDownloading || isComplete}
                >
                  {isComplete
                    ? "retrieval complete"
                    : isDownloading
                      ? "retrieval in progress..."
                      : "begin retrieval"}
                </button>
              </div>

              {error ? <div className="notice notice-error">{error}</div> : null}

              {isComplete ? (
                <div className="notice notice-success">
                  payload restored locally; relay copy consumed
                </div>
              ) : null}

              <div className="helper">
                the relay delivers the encrypted blob once, then removes it from
                storage.
              </div>
            </div>
          </div>

          <div className="panel">
            <div className="panel-header">
              <div className="panel-title">capsule facts</div>
              <div className="muted">inspection view</div>
            </div>

            <div className="panel-body stack">
              <div className="download-icon">↓</div>

              <div className="kv-grid">
                <div className="kv-row">
                  <div className="kv-key">fragment_key</div>
                  <div className="kv-value">{hasFragmentKey ? "present" : "missing"}</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">decryption_site</div>
                  <div className="kv-value">local browser runtime</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">relay_visibility</div>
                  <div className="kv-value">ciphertext only</div>
                </div>
              </div>

              <div className="mini-log">
                <div className="log-line">
                  <strong>fetch</strong> relay blob requested by transfer id
                </div>
                <div className="log-line">
                  <strong>key</strong> fragment not transmitted upstream
                </div>
                <div className="log-line">
                  <strong>restore</strong> plaintext reconstructed client-side
                </div>
              </div>
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}
