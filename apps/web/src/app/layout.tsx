import "./globals.css";
import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Zend",
  description: "Encrypted file transfer for developers",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
