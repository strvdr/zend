import Link from "next/link";

export default function HomePage() {
  return (
    <main className="page-shell">
      <div className="page-wrap home-wrap">
        <header className="header">
          <span className="header-path">zend</span>
        </header>

        <section className="home-hero">
          <p className="home-tagline">encrypted file transfer</p>
          <p className="home-desc">
            send files with a link. encrypted client-side, stored on a relay as
            ciphertext, downloaded once, then deleted. the key never leaves your
            machine.
          </p>
          <div className="actions">
            <Link href="/upload" className="button button-primary">
              upload a file
            </Link>
          </div>
        </section>

        <section className="home-section">
          <div className="home-section-label">how it works</div>
          <div className="home-steps">
            <div className="home-step">
              <span className="home-step-num">1</span>
              <div>
                <div className="home-step-title">encrypt locally</div>
                <div className="home-step-desc">
                  your file is encrypted in the browser before anything is
                  uploaded. the relay never sees plaintext.
                </div>
              </div>
            </div>
            <div className="home-step">
              <span className="home-step-num">2</span>
              <div>
                <div className="home-step-title">share a link</div>
                <div className="home-step-desc">
                  you get a URL with the decryption key in the fragment. the
                  server never receives the key.
                </div>
              </div>
            </div>
            <div className="home-step">
              <span className="home-step-num">3</span>
              <div>
                <div className="home-step-title">one download, then gone</div>
                <div className="home-step-desc">
                  the recipient decrypts client-side. the relay deletes the blob
                  after the first download.
                </div>
              </div>
            </div>
          </div>
        </section>

        <section className="home-section">
          <div className="home-section-label">cli</div>
          <div className="home-code">
            <div className="home-code-line">
              <span className="home-code-prompt">$</span>zend ./report.pdf
            </div>
            <div className="home-code-output">
              encrypting... done.
            </div>
            <div className="home-code-output">
              https://zend.dev/d/a7f3x#k=sQ9...mXw
            </div>
            <div className="home-code-comment"># recipient</div>
            <div className="home-code-line">
              <span className="home-code-prompt">$</span>zend
              https://zend.dev/d/a7f3x#k=sQ9...mXw
            </div>
            <div className="home-code-output">
              decrypting... saved to ./report.pdf
            </div>
          </div>
        </section>

        <section className="home-section">
          <div className="home-section-label">properties</div>
          <div className="home-props">
            <div className="home-prop">
              <span className="home-prop-key">encryption</span>
              <span className="home-prop-val">
                ChaCha20-Poly1305 / AES-GCM
              </span>
            </div>
            <div className="home-prop">
              <span className="home-prop-key">key exchange</span>
              <span className="home-prop-val">none — key in URL fragment</span>
            </div>
            <div className="home-prop">
              <span className="home-prop-key">relay storage</span>
              <span className="home-prop-val">ciphertext only, auto-expiry</span>
            </div>
            <div className="home-prop">
              <span className="home-prop-key">retention</span>
              <span className="home-prop-val">single download or 24h TTL</span>
            </div>
            <div className="home-prop">
              <span className="home-prop-key">clients</span>
              <span className="home-prop-val">browser, CLI (zig)</span>
            </div>
          </div>
        </section>

        <footer className="footer">
          <span>open source</span>
          <span className="separator">·</span>
          <span>no accounts</span>
          <span className="separator">·</span>
          <span>no tracking</span>
        </footer>
      </div>
    </main>
  );
}
