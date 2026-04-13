"use client";

import { useMemo, useState } from "react";
import { useParams } from "next/navigation";

export default function DownloadPage() {
  const params = useParams<{ id: string }>();
  const id = params.id;

  return <DownloadClient id={id} />;
}

function DownloadClient({ id }: { id: string }) {
  const relayUrl = process.env.NEXT_PUBLIC_RELAY_URL;
  const [isDownloading, setIsDownloading] = useState(false);
  const [error, setError] = useState("");

  const downloadUrl = useMemo(() => {
    if (!relayUrl) return "";
    return `${relayUrl}/download/${id}`;
  }, [relayUrl, id]);

  async function handleDownload() {
    if (!relayUrl) {
      setError("NEXT_PUBLIC_RELAY_URL is missing.");
      return;
    }

    try {
      setError("");
      setIsDownloading(true);

      const response = await fetch(downloadUrl);
      if (!response.ok) {
        const text = await response.text();
        throw new Error(text || `Download failed with ${response.status}`);
      }

      const blob = await response.blob();
      const objectUrl = window.URL.createObjectURL(blob);

      const a = document.createElement("a");
      a.href = objectUrl;
      a.download = `zend-${id}`;
      document.body.appendChild(a);
      a.click();
      a.remove();

      window.URL.revokeObjectURL(objectUrl);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Download failed.");
    } finally {
      setIsDownloading(false);
    }
  }

  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "4rem 1.25rem" }}>
      <h1>Download file</h1>
      <p>Ready to download this Zend transfer.</p>

      <div style={{ display: "grid", gap: 12, marginTop: 24 }}>
        <div>
          <strong>ID:</strong> {id}
        </div>

        <button
          onClick={handleDownload}
          disabled={isDownloading}
          style={{ width: "fit-content", padding: "0.75rem 1rem" }}
        >
          {isDownloading ? "Downloading..." : "Download file"}
        </button>

        {error ? (
          <p style={{ color: "crimson" }}>
            <strong>Error:</strong> {error}
          </p>
        ) : null}
      </div>
    </main>
  );
}
