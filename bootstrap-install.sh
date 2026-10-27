#!/usr/bin/env bash
# HubPOS bootstrap installer (Day 35, ADR-0046) — run this ALONE on a brand-new Linux machine that has nothing
# yet (not even a clone of this repo). It fetches the latest SIGNED release from the public
# TheVisionary10/hubpos-releases GitHub repo, verifies it with the real Ed25519 public key BEFORE running
# anything from it, extracts it, and hands off to the full first-time setup (install.sh, bundled inside the
# release itself) for everything else: dependencies, the launcher, backup/beacon prompts, and the systemd unit.
#
# One line on a brand-new machine:
#   curl -fsSL https://raw.githubusercontent.com/TheVisionary10/hubpos-releases/main/bootstrap-install.sh | bash
#
# Or download and run locally:
#   bash bootstrap-install.sh [install-dir]   # default: ~/HubPOS
#
# Safety: the signature is checked with a plain-Node, dependency-free verifier (verify-bundle-standalone.mjs,
# embedded below) BEFORE `npm install` ever runs on the downloaded content — installing untrusted dependencies
# first would defeat the point of verifying at all. A failed verification deletes everything it downloaded.

set -euo pipefail
INSTALL_DIR="${1:-$HOME/HubPOS}"

# The Ed25519 PUBLIC key every HubPOS install verifies releases against — not secret, safe to embed.
PUBLIC_KEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAHDPf/jG1ZDDvXVGqirJ8jrV2CtILkuSC5r3+apT42rY=
-----END PUBLIC KEY-----'

# ---- 1. Node.js ----
if ! command -v node >/dev/null 2>&1; then
  echo "Node.js is not installed or not on PATH. Install Node 22.13+ (nodejs.org, or your distro's package" >&2
  echo "manager / nvm) and run this script again." >&2
  exit 1
fi
echo "Using Node: $(node --version)"

# ---- 2. Find and download the latest signed release (public repo, no credentials needed) ----
echo
echo "Checking for the latest Hub POS release..."
RELEASE_JSON="$(curl -fsSL -H 'User-Agent: HubPOS-bootstrap' https://api.github.com/repos/TheVisionary10/hubpos-releases/releases/latest)"
ASSET_URL="$(node -e "const r=JSON.parse(process.argv[1]); const a=(r.assets||[]).find(x=>x.name.endsWith('.hubup')); if(!a){process.exit(1)} console.log(a.browser_download_url)" "$RELEASE_JSON")" || { echo "No .hubup release asset was found on the public releases repo." >&2; exit 1; }
TAG="$(node -e "console.log(JSON.parse(process.argv[1]).tag_name)" "$RELEASE_JSON")"
echo "Found $TAG. Downloading..."

mkdir -p "$INSTALL_DIR"
BUNDLE_PATH="$INSTALL_DIR/release.hubup"
curl -fsSL -H 'User-Agent: HubPOS-bootstrap' -o "$BUNDLE_PATH" "$ASSET_URL"

# ---- 3. Verify BEFORE extracting anything that will run (plain Node, no node_modules/tsx yet) ----
VERIFIER_PATH="$INSTALL_DIR/verify-bundle-standalone.mjs"
PUBKEY_PATH="$INSTALL_DIR/bootstrap-pubkey.pem"
printf '%s\n' "$PUBLIC_KEY" > "$PUBKEY_PATH"
# This must be a byte-for-byte copy of scripts/verify-bundle-standalone.mjs in this repo — embedded, not
# fetched, so verification never depends on trusting the very download it is about to check. A test
# (update-check.test.ts) fails if this copy and the real file ever drift apart.
cat > "$VERIFIER_PATH" <<'VERIFIER_EOF'
import fs from 'node:fs';
import crypto from 'node:crypto';
import { pathToFileURL } from 'node:url';

export function canonicalManifest(m) {
  const hashes = {};
  for (const k of Object.keys(m.hashes).sort()) hashes[k] = m.hashes[k];
  return JSON.stringify({ version: m.version, createdAt: m.createdAt, hashes });
}

export function verifyBundleStandalone(bundle, publicKeyPem) {
  try {
    if (!publicKeyPem) return { ok: false, reason: 'No public key given' };
    if (!bundle?.signature || !bundle?.hashes || !bundle?.files) return { ok: false, reason: 'That is not a valid update file' };
    const good = crypto.verify(null, Buffer.from(canonicalManifest(bundle)), publicKeyPem, Buffer.from(bundle.signature, 'base64'));
    if (!good) return { ok: false, reason: 'The signature does not match this public key' };
    for (const [p, hash] of Object.entries(bundle.hashes)) {
      const raw = bundle.files[p];
      if (raw === undefined) return { ok: false, reason: `Missing file: ${p}` };
      if (crypto.createHash('sha256').update(Buffer.from(raw, 'base64')).digest('hex') !== hash) return { ok: false, reason: `A file was altered: ${p}` };
    }
    return { ok: true, version: bundle.version, fileCount: Object.keys(bundle.files).length };
  } catch (e) { return { ok: false, reason: e.message }; }
}

// CLI entry point — only when run directly (`node verify-bundle-standalone.mjs ...`), not when imported by the
// test. Compared via pathToFileURL (not a plain `file://${...}` template), which is the only reliable way to
// match this on Windows (backslashes, drive letters, URL-encoding all differ from a raw path).
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [bundlePath, pubkeyPath] = process.argv.slice(2);
  if (!bundlePath || !pubkeyPath) { console.error('Usage: node verify-bundle-standalone.mjs <bundle.hubup> <publicKey.pem>'); process.exit(2); }
  const bundle = JSON.parse(fs.readFileSync(bundlePath, 'utf8'));
  const pubkey = fs.readFileSync(pubkeyPath, 'utf8');
  const r = verifyBundleStandalone(bundle, pubkey);
  if (!r.ok) { console.error(`REJECTED: ${r.reason}`); process.exit(1); }
  console.log(`Verified ${r.version} — ${r.fileCount} files, signature and hashes all match.`);
  process.exit(0);
}
VERIFIER_EOF

echo "Verifying the signature..."
if ! node "$VERIFIER_PATH" "$BUNDLE_PATH" "$PUBKEY_PATH"; then
  echo "Signature verification FAILED — this is not a genuine, untampered Hub POS release. Removing everything that was downloaded." >&2
  rm -rf "$INSTALL_DIR"
  exit 1
fi
rm -f "$PUBKEY_PATH" "$VERIFIER_PATH"

# ---- 4. Extract the verified bundle ----
echo "Extracting..."
node -e "
const fs = require('fs'); const path = require('path');
const bundle = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
const dir = process.argv[2];
for (const [rel, b64] of Object.entries(bundle.files)) {
  const dest = path.join(dir, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, Buffer.from(b64, 'base64'));
}
" "$BUNDLE_PATH" "$INSTALL_DIR"
rm -f "$BUNDLE_PATH"

# ---- 5. Hand off to the full first-time setup (now present, just extracted) ----
echo
echo "Verified and extracted $TAG into $INSTALL_DIR. Handing off to the full setup..."
echo
cd "$INSTALL_DIR"
chmod +x scripts/install.sh scripts/install-service.sh scripts/uninstall-service.sh 2>/dev/null || true
bash scripts/install.sh
