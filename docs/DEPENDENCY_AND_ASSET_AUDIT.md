# Noiro dependency and asset audit

Status: **open — release blocked**

| Area | Current evidence | Release decision |
|---|---|---|
| Prismatic N | New generated masters and deterministic asset generator are tracked | Pending name and asset-rights review |
| App source | GPL-3.0 history retained | Matching-source process implemented; release evidence pending |
| MPVKit-GPL / mpv / FFmpeg | Exact MPVKit revision recorded | License texts, codec configuration, and corresponding sources pending final audit |
| Local KSPlayer adaptation | Source and license tracked | Modification/source inventory pending final audit |
| stremio-core adaptation | Source history retained | Rights and all inherited network dependencies pending review |
| Stremio `server.js` | Proprietary file exists only in the ignored developer workspace | **Launch blocker:** written commercial redistribution and GPL-compatibility permission, or replacement, required |
| Provider and debrid integration | Credentials remain device-local | Provider terms and branding review pending |
| Metadata, poster, rating, subtitle, skip, and source signals | Inherited production hosts removed or adapters fail closed | Rights-reviewed Noiro-owned services and parity tests pending |
| Trailers | Official direct URLs are the only allowed release design | Proxy/clip hosting prohibited; runtime audit pending |
| Trickplay | Required release design is device-generated and device-cached | Real-device performance test pending |
| Telemetry | Default off; raw playback URLs are prohibited | Consent, retention, redaction, and deletion review pending |

## Required evidence

- A Software Bill of Materials and exact dependency/source revisions.
- License text and notice mapping for every shipped file and framework.
- Static and runtime proof of zero inherited domains, secrets, signing roots,
  update feeds, and owner/support links.
- Ownership or permission evidence for every icon, logo, screenshot, font,
  provider mark, metadata feed, and service.
- A real-device parity matrix for iPhone, iPad, Apple TV, and Mac.

The audit is not complete merely because the project compiles.
