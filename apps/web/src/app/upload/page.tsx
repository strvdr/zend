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

  const status = useMemo(() => {
    if (error) return "error";
    if (result) return "ready";
    if (isUploading) return "encrypting";
    if (file) return "staged";
    return "idle";
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

  function resetSession() {
    setFile(null);
    setResult(null);
    setShareUrl("");
    setError("");
    setCopied(false);
  }

  if (!mounted) return null;

  return (
    <main className="page-shell">
      <div className="page-wrap">
        {/* Header */}
        <header className="header">
          <span className="header-path">zend</span>
          <span className="header-dot" data-status={status} />
        </header>

        {/* Drop zone */}
        <label
          className={`dropzone${dragging ? " dragging" : ""}${file ? " has-file" : ""}`}
          onDragEnter={() => setDragging(true)}
          onDragLeave={() => setDragging(false)}
          onDrop={() => setDragging(false)}
        >
          <input
            type="file"
            onChange={(e) => {
              setFile(e.target.files?.[0] ?? null);
              setResult(null);
              setShareUrl("");
              setError("");
            }}
          />
          {file ? (
            <div className="file-info">
              <span className="file-name">{file.name}</span>
              <span className="file-size">{formatBytes(file.size)}</span>
            </div>
          ) : (
            <div className="drop-prompt">
              <span>drop a file here or click to browse</span>
            </div>
          )}
        </label>

        {/* Actions */}
        <div className="actions">
          <button
            className="button button-primary"
            onClick={handleUpload}
            disabled={!file || isUploading}
          >
            {isUploading ? "encrypting..." : "create link"}
          </button>
          {file && (
            <button className="button button-ghost" onClick={resetSession}>
              clear
            </button>
          )}
        </div>

        {/* Error */}
        {error && <div className="notice notice-error">{error}</div>}

        {/* Result */}
        {result && (
          <section className="result">
            <div className="result-label">share link</div>
            <div className="result-url">{shareUrl}</div>
            <div className="result-actions">
              <button className="button button-primary" onClick={handleCopy}>
                {copied ? "copied" : "copy"}
              </button>
              <a
                className="button button-ghost"
                href={shareUrl}
                target="_blank"
                rel="noreferrer"
              >
                open
              </a>
            </div>
            <div className="result-meta">
              <span>id: {result.id}</span>
              <span className="separator">·</span>
              <span>single-use</span>
              <span className="separator">·</span>
              <span>key stays after #</span>
            </div>
          </section>
        )}

        {/* Footer info */}
        <footer className="footer">
          <span>encrypted client-side</span>
          <span className="separator">·</span>
          <span>relay sees ciphertext only</span>
          <span className="separator">·</span>
          <span>expires in 24h</span>
        </footer>
      </div>
    </main>
  );
}
