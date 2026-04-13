"use client";

import { useEffect, useMemo, useState } from "react";

type UploadResponse = {
  id: string;
  token: string;
};

export default function UploadPage() {
  const relayUrl = process.env.NEXT_PUBLIC_RELAY_URL;
  const appUrl = process.env.NEXT_PUBLIC_APP_URL ?? "http://localhost:3000";

  const [mounted, setMounted] = useState(false);
  const [file, setFile] = useState<File | null>(null);
  const [isUploading, setIsUploading] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState<UploadResponse | null>(null);

  useEffect(() => {
    setMounted(true);
  }, []);

  const shareUrl = useMemo(() => {
    if (!result) return "";
    return `${appUrl}/d/${result.id}`;
  }, [appUrl, result]);

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
      setIsUploading(true);

      const response = await fetch(`${relayUrl}/upload`, {
        method: "POST",
        body: file,
      });

      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Upload failed with ${response.status}`);
      }

      const json = (await response.json()) as UploadResponse;
      setResult(json);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Upload failed.");
    } finally {
      setIsUploading(false);
    }
  }

  if (!mounted) return null;

  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "4rem 1.25rem" }}>
      <h1>Upload</h1>
      <p>Send a file to the Zend relay.</p>

      <div style={{ display: "grid", gap: 12, marginTop: 24 }}>
        <input
          type="file"
          onChange={(e) => setFile(e.target.files?.[0] ?? null)}
        />

        {file ? (
          <div>
            <strong>Selected:</strong> {file.name} ({file.size} bytes)
          </div>
        ) : null}

        <button
          onClick={handleUpload}
          disabled={!file || isUploading}
          style={{ width: "fit-content", padding: "0.75rem 1rem" }}
        >
          {isUploading ? "Uploading..." : "Upload file"}
        </button>

        {error ? <p style={{ color: "crimson" }}>{error}</p> : null}

        {result ? (
          <div style={{ padding: 16, border: "1px solid #ccc", marginTop: 12 }}>
            <p><strong>Upload complete</strong></p>
            <p>ID: {result.id}</p>
            <p>Token: {result.token}</p>
            <p>
              Download link: <a href={shareUrl}>{shareUrl}</a>
            </p>
          </div>
        ) : null}
      </div>
    </main>
  );
}
