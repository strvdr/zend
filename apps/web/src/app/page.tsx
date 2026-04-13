import Link from "next/link";

export default function HomePage() {
  return (
    <main style={{ maxWidth: 720, margin: "0 auto", padding: "4rem 1.25rem" }}>
      <h1>Zend</h1>
      <p>Fast file transfer for developers.</p>
      <p>
        <Link href="/upload">Go to upload</Link>
      </p>
    </main>
  );
}
