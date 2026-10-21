# Hub POS — signed releases

This repo holds **signed update files** for [The Hub Visionary POS](https://github.com/TheVisionary10/HubPOS) —
nothing else. It is deliberately public: every file here is a `.hubup` bundle, Ed25519-signed by the developer's
private key, and **verified against that signature before a shop will ever apply it** (see `server/src/release.ts`
and `scripts/update-apply.ts` in the main repo). A public release file is exactly as safe as this scheme makes it —
the same trust model most desktop software uses for its auto-updater.

No shop's data, credentials, or source code lives here. Each shop runs its own private copy of the main `HubPOS`
repo; this repo exists only so every shop's installation can check for and download the latest signed release
without needing a private-repo access token of its own.

## Releases
Each GitHub Release here corresponds to one signed `.hubup` bundle, built with `npm run release:sign` in the main
repo. The release notes name the version and what changed (see the main repo's `CHANGELOG.md` for detail).

## Status
Set up 2026-10-21. The shop-side auto-update client that checks this repo automatically is not built yet — today,
applying a release here still means downloading the `.hubup` file by hand and running
`npm run update:apply -- <file> --target <folder>` on the shop PC, exactly as the manual-email flow already
worked. See the main repo's `docs/OWNER-SETUP-PLAN.md` Phase 6 for the plan.
