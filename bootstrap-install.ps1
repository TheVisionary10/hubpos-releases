# HubPOS bootstrap installer (Day 35, ADR-0046) — run this ALONE on a brand-new Windows machine that has
# nothing yet (not even a clone of this repo). It fetches the latest SIGNED release from the public
# TheVisionary10/hubpos-releases GitHub repo, verifies it with the real Ed25519 public key BEFORE running
# anything from it, extracts it, and hands off to the full first-time setup (install.ps1, bundled inside the
# release itself) for everything else: dependencies, the desktop launcher, backup/beacon prompts, and the
# boot-time service.
#
# One line on a brand-new PC (PowerShell, as the person who will use the machine):
#   irm https://raw.githubusercontent.com/TheVisionary10/hubpos-releases/main/bootstrap-install.ps1 | iex
#
# Or download and run locally:
#   powershell -ExecutionPolicy Bypass -File bootstrap-install.ps1 [-InstallDir "C:\HubPOS"]
#
# Safety: the signature is checked with a plain-Node, dependency-free verifier (verify-bundle-standalone.mjs,
# embedded below) BEFORE `npm install` ever runs on the downloaded content — installing untrusted dependencies
# first would defeat the point of verifying at all. A failed verification deletes everything it downloaded.

param([string]$InstallDir = "$env:USERPROFILE\HubPOS")

$ErrorActionPreference = 'Stop'

# The Ed25519 PUBLIC key every HubPOS install verifies releases against — not secret, safe to embed.
$PUBLIC_KEY = @'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAHDPf/jG1ZDDvXVGqirJ8jrV2CtILkuSC5r3+apT42rY=
-----END PUBLIC KEY-----
'@

# ---- 1. Node.js ----
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
  Write-Host "Node.js is not installed. Trying to install it with winget..."
  $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
  if ($winget) {
    winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
    # winget updates PATH for new shells, not this one — look in the usual install location too
    $env:Path = "$env:ProgramFiles\nodejs;$env:Path"
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  }
  if (-not $node) {
    Write-Error "Could not install Node.js automatically. Install Node 22.13+ from https://nodejs.org, then run this script again."
    exit 1
  }
}
Write-Host "Using Node: $(node --version)"

# ---- 2. Find and download the latest signed release (public repo, no credentials needed) ----
Write-Host "`nChecking for the latest Hub POS release..."
$release = Invoke-RestMethod -Uri "https://api.github.com/repos/TheVisionary10/hubpos-releases/releases/latest" -Headers @{ 'User-Agent' = 'HubPOS-bootstrap' }
$asset = $release.assets | Where-Object { $_.name -like '*.hubup' } | Select-Object -First 1
if (-not $asset) { Write-Error "No .hubup release asset was found on the public releases repo."; exit 1 }
Write-Host "Found $($release.tag_name) ($($asset.name)). Downloading..."

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$bundlePath = Join-Path $InstallDir $asset.name
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $bundlePath -Headers @{ 'User-Agent' = 'HubPOS-bootstrap' }

# ---- 3. Verify BEFORE extracting anything that will run (the standalone verifier is plain Node, no
# node_modules/tsx needed — those do not exist on this machine yet) ----
$verifierPath = Join-Path $InstallDir 'verify-bundle-standalone.mjs'
$pubkeyPath = Join-Path $InstallDir 'bootstrap-pubkey.pem'
Set-Content -Path $pubkeyPath -Value $PUBLIC_KEY -Encoding ASCII
# This must be a byte-for-byte copy of scripts/verify-bundle-standalone.mjs in this repo — it is embedded,
# not fetched, so verification never depends on trusting the very download it is about to check. A test
# (update-check.test.ts) fails if this copy and the real file ever drift apart.
@'
#!/usr/bin/env node
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
'@ | Set-Content -Path $verifierPath -Encoding UTF8

Write-Host "Verifying the signature..."
& node $verifierPath $bundlePath $pubkeyPath
if ($LASTEXITCODE -ne 0) {
  Write-Error "Signature verification FAILED — this is not a genuine, untampered Hub POS release. Removing everything that was downloaded."
  Remove-Item -Recurse -Force $InstallDir -ErrorAction SilentlyContinue
  exit 1
}
Remove-Item $pubkeyPath, $verifierPath -Force

# ---- 4. Extract the verified bundle ----
Write-Host "Extracting..."
$bundle = Get-Content $bundlePath -Raw | ConvertFrom-Json
foreach ($rel in $bundle.files.PSObject.Properties.Name) {
  $dest = Join-Path $InstallDir $rel
  New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
  [IO.File]::WriteAllBytes($dest, [Convert]::FromBase64String($bundle.files.$rel))
}
Remove-Item $bundlePath -Force

# ---- 5. Hand off to the full first-time setup (now present, just extracted) ----
Write-Host "`nVerified and extracted $($bundle.version) into $InstallDir. Handing off to the full setup...`n"
Set-Location $InstallDir
& "$InstallDir\scripts\install.ps1"
