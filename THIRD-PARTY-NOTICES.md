# Third-party notices

Noiro builds on third-party components, each retained under its own license.
This file is an inventory aid and does not replace the license texts or the
exact dependency audit required for a release.

- **stremio-core** — MIT; currently adapted as the native catalog/engine layer.
  Its use and every service dependency must pass the Noiro rights review.
- **MPVKit / mpv / FFmpeg components** — the MPVKit-GPL product is used. GPL
  notices and exact corresponding source packages are mandatory.
- **KSPlayer-derived integration** — local source package; its license and every
  transitive codec component must be included in the release audit.
- **nodejs-mobile / Node.js** — runtime components under their respective
  licenses.
- **Stremio `server.js`** — proprietary, stored only in the developer's ignored
  local workspace. It is not authorized for a Noiro sale or public release.
  Written commercial redistribution and GPL-compatibility permission, or a
  compatible open-source replacement, is required.
- **Prismatic N artwork** — newly generated for the Noiro working identity;
  retain its generation record and complete the asset-rights review before use.
- **Kodi** — maintained as a separate fork of `xbmc/xbmc` in
  `NoiroTV/noiro-kodi-engine` and referenced through `vendor/kodi`. Kodi retains
  its upstream notices, contributor history, and applicable GPL license terms.
  NoiroTV is not affiliated with or endorsed by the Kodi Foundation.

See `docs/DEPENDENCY_AND_ASSET_AUDIT.md` and
`docs/GPL_SOURCE_AND_DISTRIBUTION.md` for the release checklist.
