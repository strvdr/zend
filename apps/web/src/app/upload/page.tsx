"use client";

import { useEffect, useMemo, useState } from "react";
import { encryptFile } from "@/lib/wasm/zend";

type UploadResponse = {
  id: string;
  token: string;
};

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

export default function UploadPage() {
  const relayUrl = process.env.NEXT_PUBLIC_RELAY_URL;
  const appUrl = process.env.NEXT_PUBLIC_APP_URL ?? "http://localhost:3000";

  const [mounted, setMounted] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState<UploadResponse | null>(null);
  const [shareUrl, setShareUrl] = useState("");
  const [copied, setCopied] = useState(false);
  const [dragging, setDragging] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  const activeStage = useMemo(() => {
    if (error) return 0;
    if (result) return 5;
    if (isUploading) return 3;
    if (file) return 1;
    return 0;
  }, [error, result, isUploading, file]);

  async function handleUpload() {
    if (!relayUrl) {
      setError("NEXT_PUBLIC_RELAY_URL is missing.");
      return;
    }

    if (!file) {
      setError("Choose a file first.");
      return;
    }

    try {
      setError("");
      setResult(null);
      setShareUrl("");
      setCopied(false);
      setIsUploading(true);

      const { blob, keyB64 } = await encryptFile(file);

      const response = await fetch(`${relayUrl}/upload`, {
        method: "POST",
        body: blob,
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Upload failed with ${response.status}`);
      }

      const json = (await response.json()) as UploadResponse;
      setResult(json);
      setShareUrl(`${appUrl}/d/${json.id}#${keyB64}`);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Upload failed unexpectedly.";
      setError(message);
    } finally {
      setIsUploading(false);
    }
  }

  async function handleCopy() {
    if (!shareUrl) return;
    await navigator.clipboard.writeText(shareUrl);
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1400);
  }

  function stageState(index: number) {
    if (error && index >= 2) return "stage-error";
    if (result && index <= 5) return "stage-done";
    if (isUploading && index < activeStage) return "stage-done";
    if (isUploading && index === activeStage) return "stage-active";
    if (!isUploading && file && index === 1) return "stage-active";
    return "stage-idle";
  }

  function stageText(index: number) {
    if (error && index >= 2) return "fault";
    if (result && index <= 5) return "done";
    if (isUploading && index < activeStage) return "done";
    if (isUploading && index === activeStage) return "live";
    if (!isUploading && file && index === 1) return "ready";
    return "idle";
  }

  if (!mounted) return null;

  return (
    <main className="page-shell">
      <div className="page-wrap">
        <section className="session-header">
          <div className="session-top">
            <div className="session-title">
              <span className="session-chip">zend://session uplink_01</span>
              <h1>secure transfer console</h1>
            </div>
            <div className="session-status">
              {result ? "capsule armed" : isUploading ? "uplink live" : "standing by"}
            </div>
          </div>

          <div className="session-grid">
            <div className="session-stat">
              <div className="session-stat-label">transport</div>
              <div className="session-stat-value">relay</div>
            </div>
            <div className="session-stat">
              <div className="session-stat-label">cipher</div>
              <div className="session-stat-value">zend/wasm</div>
            </div>
            <div className="session-stat">
              <div className="session-stat-label">retrieval</div>
              <div className="session-stat-value">one-shot</div>
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
              <div className="panel-title">transfer pipeline</div>
              <div className="muted">local encryption path</div>
            </div>

            <div className="panel-body stack">
              <label
                className={`dropzone ${dragging ? "dragging" : ""}`}
                onDragEnter={() => setDragging(true)}
                onDragLeave={() => setDragging(false)}
                onDrop={() => setDragging(false)}
              >
                <input
                  type="file"
                  onChange={(e) => setFile(e.target.files?.[0] ?? null)}
                />
                <p className="dropzone-title">acquire payload</p>
                <p className="dropzone-subtitle">
                  inject a file into the session. zend will derive key material,
                  encrypt locally, commit ciphertext to relay, and issue a retrieval capsule.
                </p>
              </label>

              {file ? (
                <div className="file-box">
                  <div className="file-name">{file.name}</div>
                  <div className="file-meta">{formatBytes(file.size)}</div>
                </div>
              ) : null}

              <div className="pipeline">
                <div className="stage-row">
                  <div className="stage-index">[01]</div>
                  <div className="stage-name">acquire payload</div>
                  <div className={`stage-state ${stageState(1)}`}>{stageText(1)}</div>
                </div>
                <div className="stage-row">
                  <div className="stage-index">[02]</div>
                  <div className="stage-name">derive transfer capsule</div>
                  <div className={`stage-state ${stageState(2)}`}>{stageText(2)}</div>
                </div>
                <div className="stage-row">
                  <div className="stage-index">[03]</div>
                  <div className="stage-name">encrypt locally</div>
                  <div className={`stage-state ${stageState(3)}`}>{stageText(3)}</div>
                </div>
                <div className="stage-row">
                  <div className="stage-index">[04]</div>
                  <div className="stage-name">commit ciphertext to relay</div>
                  <div className={`stage-state ${stageState(4)}`}>{stageText(4)}</div>
                </div>
                <div className="stage-row">
                  <div className="stage-index">[05]</div>
                  <div className="stage-name">issue retrieval link</div>
                  <div className={`stage-state ${stageState(5)}`}>{stageText(5)}</div>
                </div>
              </div>

              <div className="actions">
                <button
                  className="button"
                  onClick={handleUpload}
                  disabled={!file || isUploading}
                >
                  {isUploading ? "processing session..." : "begin transfer"}
                </button>

                <button
                  className="button button-secondary"
                  onClick={() => {
                    setFile(null);
                    setResult(null);
                    setShareUrl("");
                    setError("");
                    setCopied(false);
                  }}
                >
                  clear session
                </button>
              </div>

              {error ? <div className="notice notice-error">{error}</div> : null}

              {result ? (
                <div className="notice notice-success">
                  relay commit accepted; retrieval capsule issued
                </div>
              ) : null}
            </div>
          </div>

          <div className="panel">
            <div className="panel-header">
              <div className="panel-title">active payload</div>
              <div className="muted">session facts</div>
            </div>

            <div className="panel-body stack">
              <div className="kv-grid">
                <div className="kv-row">
                  <div className="kv-key">payload_name</div>
                  <div className="kv-value">{file?.name ?? "none"}</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">payload_size</div>
                  <div className="kv-value">{file ? formatBytes(file.size) : "n/a"}</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">delivery_mode</div>
                  <div className="kv-value">single retrieval</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">relay_visibility</div>
                  <div className="kv-value">ciphertext only</div>
                </div>
              </div>

              <div className="mini-log">
                <div className="log-line">
                  <strong>session</strong> waiting for payload injection
                </div>
                <div className="log-line">
                  <strong>crypto</strong> key material remains client-side
                </div>
                <div className="log-line">
                  <strong>relay</strong> stores opaque zend blob only
                </div>
              </div>
            </div>
          </div>
        </section>

        {result ? (
          <section className="panel" style={{ marginTop: 16 }}>
            <div className="panel-header">
              <div className="panel-title">retrieval capsule</div>
              <div className="muted">sealed output</div>
            </div>

            <div className="panel-body stack">
              <div className="kv-grid">
                <div className="kv-row">
                  <div className="kv-key">transfer_id</div>
                  <div className="kv-value">{result.id}</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">relay_target</div>
                  <div className="kv-value">{relayUrl}</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">fragment_key</div>
                  <div className="kv-value">attached</div>
                </div>
                <div className="kv-row">
                  <div className="kv-key">delete_token</div>
                  <div className="kv-value">{result.token}</div>
                </div>
              </div>

              <div className="link-box">
                <div className="kv-key">raw_capsule_url</div>
                <div className="link-raw">{shareUrl}</div>
              </div>

              <div className="actions">
                <button className="button" onClick={handleCopy}>
                  {copied ? "copied" : "copy capsule"}
                </button>
                <a
                  className="button button-secondary"
                  href={shareUrl}
                  target="_blank"
                  rel="noreferrer"
                >
                  open retrieval
                </a>
              </div>

              <div className="helper">
                key material is stored after <code>#</code> and never transmitted to the relay.
              </div>
            </div>
          </section>
        ) : null}
      </div>
    </main>
  );
}
