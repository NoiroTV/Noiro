# Noiro roadmap

Noiro is in private development. Dates and sales are intentionally omitted
until the release gates are satisfied.

## Foundation implemented

- Prismatic N identity and canonical Apple bundle identifiers.
- Native iPhone/iPad, Apple TV, and Mac schemes.
- Optional Noiro Sync client with verifier-bound device pairing, signed safe
  configuration, and a device-encrypted opaque vault.
- Device-local credential migration and fail-closed inherited-service adapters.
- Vortexo Shop, Library, Studio, entitlement, claim, release, and MovieLeaks
  interfaces in the separate website repository.

## Required before a sale

- Clear the Noiro name or switch once to Noirvo.
- Obtain permission for, or replace, proprietary `server.js`.
- Complete Apple-platform feature parity and real-device playback testing.
- Replace every inherited service and signing root with rights-reviewed,
  Noiro-owned infrastructure.
- Finish dependency, codec, artwork, metadata, trailer, subtitle, and service
  rights reviews.
- Produce notarized macOS packages and customer-signable Xcode packages with a
  matching GPL source archive for every binary.
- Approve privacy, retention, processor, export, deletion, refund, and customer
  registration policies.

`scripts/noiro-release-gate.sh` is the executable source of truth. The full gate
is expected to fail until all approvals are real; bypassing it is not a release
process.
