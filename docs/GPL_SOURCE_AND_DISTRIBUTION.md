# GPL source and distribution requirements

Noiro's tracked application source is GPL-3.0. A purchase is an entitlement to
official downloads and updates, not a restriction on the GPL rights received
with a covered binary.

Every binary release must place these artifacts together in Vortexo Library:

- the signed binary or Xcode package;
- one exact corresponding-source archive from the same Git commit;
- the generated project specification, local package source, dependency lock,
  patches, scripts, and complete build instructions;
- license and third-party notice files;
- a signed release manifest with the Git commit and SHA-256 checksum of every
  artifact.

The source archive must be sufficient for a recipient to rebuild the covered
work. It must not omit a locally modified dependency, build script, generated
source needed for reproducibility, or installation information required by the
GPL version in `LICENSE`.

Proprietary material cannot be silently folded into the GPL release. The local
Stremio `server.js` is ignored by Git and is a hard release blocker until written
commercial redistribution and GPL-compatibility permission is retained with
the release record, or the file is replaced by a compatible open-source
implementation whose complete source is included.

`scripts/build-noiro-source-package.sh <version> <output-directory>` creates a
source archive only from a clean, committed tree and records its checksum. It
does not approve or create a binary release. The full release gate must pass
before that archive is associated with a customer binary.
