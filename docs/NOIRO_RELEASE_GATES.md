# Noiro release gates

Noiro must not be sold, published, notarized as a customer release, or exposed
through public registration until every full gate is supported by retained
evidence.

## Automated static gate

Run:

```sh
scripts/noiro-release-gate.sh --static
```

It rejects inherited domains, signing-secret identifiers, old repository links,
obsolete direct-install artifacts, wrong canonical identifiers, missing notices,
or a project that no longer generates the required Noiro schemes.

## Full gate

Run:

```sh
scripts/noiro-release-gate.sh
```

The full gate also requires every boolean and evidence field in
`release/noiro-release-approvals.json`, a clean committed tree, and matching
artifact/source records. The checked-in approvals intentionally start false.

Required approvals cover:

1. Noiro name clearance or the one-time Noirvo fallback decision.
2. `server.js` permission and GPL compatibility, or open-source replacement.
3. Dependency, codec, service, metadata, artwork, and provider rights.
4. Apple-platform feature parity and real-device playback.
5. Realm isolation, pairing, safe-configuration signature, vault, entitlement,
   and recovery test suites.
6. Developer ID signing, hardened runtime, notarization, Gatekeeper, and
   customer Xcode signing.
7. Exact GPL source archives and signed artifact manifests.
8. Privacy, retention, processor, refund, export, deletion, and public
   registration approval.

No script flag may bypass a false approval. Development builds remain permitted;
they are not customer releases.
