"use client";

import { useEffect, useMemo, useState } from "react";
import { uploadEncryptedFileChunked } from "@/lib/wasm/zend";

type UploadResponse = {
  id: string;
  token: string;
};

type UploadProgressState = {
  fileBytesTotal: number;
  fileBytesProcessed: number;
  chunkIndex: number;
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
  const [phase, setPhase] = useState<"idle" | "encrypting" | "uploading">("idle");
  const [progress, setProgress] = useState<UploadProgressState | null>(null);
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
    if (isUploading) return phase === "uploading" ? "uploading" : "encrypting";
    if (file) return "staged";
    return "idle";
  }, [error, result, isUploading, file, phase]);

  const progressPercent = useMemo(() => {
    if (!progress || progress.fileBytesTotal <= 0) return 0;
    return Math.max(
      0,
      Math.min(
        100,
        Math.floor((progress.fileBytesProcessed / progress.fileBytesTotal) * 100),
      ),
    );
  }, [progress]);

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
      setProgress(null);
      setIsUploading(true);
      setPhase("encrypting");

      const uploaded = await uploadEncryptedFileChunked(
        relayUrl,
        file,
        (nextPhase) => setPhase(nextPhase),
        (nextProgress) => {
          setProgress({
            fileBytesTotal: nextProgress.fileBytesTotal,
            fileBytesProcessed: nextProgress.fileBytesProcessed,
            chunkIndex: nextProgress.chunkIndex,
          });
        },
      );

      setResult({
        id: uploaded.id,
        token: uploaded.token,
      });
      setShareUrl(`${appUrl}/d/${uploaded.id}#${uploaded.keyB64}`);
      setPhase("idle");
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Upload failed unexpectedly.";
      setError(message);
      setPhase("idle");
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
    setProgress(null);
    setPhase("idle");
  }

  if (!mounted) return null;

  return (
    <main className="page-shell">
      <div className="page-wrap">
        <header className="header">
          <span className="header-path">zend</span>
          <span className="header-dot" data-status={status} />
        </header>

        <label
          className={`dropzone${dragging ? " dragging" : ""}${file ? " has-file" : ""}`}
          onDragEnter={() => setDragging(true)}
          onDragLeave={() => setDragging(false)}
          onDrop={() => setDragging(false)}
        >
          <input
            type="file"
            disabled={isUploading}
            onChange={(e) => {
              setFile(e.target.files?.[0] ?? null);
              setResult(null);
              setShareUrl("");
              setError("");
              setCopied(false);
              setProgress(null);
              setPhase("idle");
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

        <div className="actions">
          <button
            className="button button-primary"
            onClick={handleUpload}
            disabled={!file || isUploading}
          >
            {phase === "encrypting"
              ? "encrypting…"
              : phase === "uploading"
                ? "uploading…"
                : "create link"}
          </button>

          {file && (
            <button
              className="button button-ghost"
              onClick={resetSession}
              disabled={isUploading}
            >
              clear
            </button>
          )}
        </div>

        {isUploading && progress && (
          <div className="notice">
            <div>{progressPercent}%</div>
            <div>
              {formatBytes(progress.fileBytesProcessed)} /{" "}
              {formatBytes(progress.fileBytesTotal)}
            </div>
            <div className="result-meta">
              <span>chunk {progress.chunkIndex}</span>
            </div>
          </div>
        )}

        {error && <div className="notice notice-error">{error}</div>}

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

        <footer className="footer">
          <span>encrypted client-side</span>
          <span className="separator">·</span>
          <span>relay sees ciphertext only</span>
          <span className="separator">·</span>
          <span>chunked upload path</span>
        </footer>
      </div>
    </main>
  );
}
