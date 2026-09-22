# Noiro security policy

## Release status

No public Noiro release is supported yet. Preview builds are for isolated local
testing and may contain unfinished or rights-review-gated features.

## Private reporting

Use GitHub private vulnerability reporting on `NoiroTV/Noiro` for security
issues. Do not put credentials, media URLs, pairing tokens, recovery keys,
private manifests, or payment data in a public issue.

The highest-priority areas are:

- device-code verifier binding, replay prevention, and device revocation;
- entitlement and product-realm isolation;
- signed safe configuration and encrypted vault handling;
- localhost services, keychain data, and log redaction;
- artifact authorization, signatures, checksums, notarization, and matching GPL
  source archives.

## Release verification

Noiro release metadata and download grants will be served from the signed-in
Vortexo Library. A release is valid only when its signed manifest, binary
checksum, and matching GPL source-archive checksum agree. The website never
collects Apple account credentials.
