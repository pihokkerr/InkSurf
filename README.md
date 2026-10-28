# InkSurf

A real web browser for jailbroken Kindle, as a **KOReader plugin**. InkSurf
embeds the **NetSurf** engine (framebuffer frontend, limited JavaScript) so pages
with logins, forms, images and most file types work — things the stock Kindle
browser can't do. It adds a touch toolbar, on-screen input via KOReader's own
keyboard, downloads, torrent, OpenVPN, ad-blocking, reader mode and azw3→EPUB
conversion.

> Status: works on a jailbroken Kindle Paperwhite (MTK / `hwtcon_v2`, e.g. PW5/PW6)
> with KOReader. Built and tested against KOReader 2026.07.02.

## Features
- NetSurf engine with a custom e-ink touch toolbar (back / forward / reload /
  reader / minimize / close) and tap-to-type URL bar using KOReader's keyboard.
- **In-page text fields**: tap a field → KOReader keyboard opens over the frozen
  page → your text is typed into the field (existing content is pre-loaded and
  replaced).
- Minimize / resume (the browser stays in the background; resume where you left off).
- Pinch-zoom, drag-to-pan, horizontal scroll.
- Reader mode (local, private — no third-party extraction service).
- Downloads to `koreader/documents`; `.torrent` handed to a built-in aria2 manager.
- azw3 (and other unsupported formats) → EPUB conversion, original deleted after.
- OpenVPN support (any provider; per-server credentials) with kill-switch + DNS
  protection.
- Host-based ad/tracker blocking during browsing (restored on exit).
- UI in **English / Hungarian / German**, switchable in Settings.
- Self-contained: all data lives in the plugin's own `data/` subfolder; a
  "Full cleanup / reset" button and uninstall = delete the folder.

## Requirements
- A **jailbroken** Kindle with **KOReader** installed.
- MTK-class device (PW5/PW6 and similar, `hwtcon_v2` e-ink). Other Kindles may need
  changes to the framebuffer surface.

## Install (prebuilt)
1. Download the plugin zip from **Releases**.
2. Copy the `inksurf.koplugin` folder into `koreader/plugins/`.
3. Restart KOReader. Open it from the main menu or KOReader Settings.
4. (Optional) For VPN, drop your own `.ovpn` + `.auth` into `inksurf.koplugin/vpn/`
   — see `vpn/README.txt`. **No VPN credentials are shipped in this repo.**

## Build the engine yourself
The NetSurf binary is built by `build.sh` via GitHub Actions
(`.github/workflows/build.yml`), using a `koxtoolchain` `kindlehf` cross-toolchain
(built and cached by the workflow). `build.sh` downloads `netsurf-all-3.11`,
cross-builds the dependencies, embeds the Kindle framebuffer surface and applies the
InkSurf patches, and writes the results to `out/`. The workflow uploads them as the
`netsurf-kindle` artifact; download it and copy `netsurf` and `res/` into
`inksurf.koplugin/bin/`.

## Debugging
Logging is **off by default**. Settings → "Debug log" turns on verbose logging to
`data/netsurf.log` and `data/netsurf_field.log` for troubleshooting.

## License
GPL-2.0-or-later. The project builds and ships a modified NetSurf (GPL-2.0), so the
NetSurf patches in `build.sh` are GPL-2.0. See `LICENSE` and `THIRD_PARTY_NOTICES.md`
for bundled components (NetSurf, aria2, OpenVPN, FBInk, libmobi, fonts, CA bundle)
and their licenses/sources.

## Credits
Engine: **NetSurf**. Runs inside **KOReader**. Reader-mode idea inspired by
`omer-faruq/webbrowser.koplugin` (independent local implementation). See
`THIRD_PARTY_NOTICES.md`.

## Disclaimer
For a device **you own and have modified yourself**. Jailbreaking may void your
warranty and can violate the device vendor's terms of service. Use responsibly and
only for lawful purposes. Provided "as is", without warranty of any kind.

---

### Quick summary
A real web browser for jailbroken Kindle, packaged as a KOReader plugin and powered
by **NetSurf**. To install, copy the `inksurf.koplugin` folder into
`koreader/plugins/` and restart KOReader. For VPN support, put your own `.ovpn` and
`.auth` files in the `vpn/` folder (the repository contains **no** VPN credentials).
The interface language (English/Hungarian/German) can be changed in Settings.
License: GPL-2.0-or-later; see `THIRD_PARTY_NOTICES.md` for bundled component licenses.
