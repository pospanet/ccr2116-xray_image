# Changelog

## v0.2

- Replaces the file-mode group/other permission-bit heuristic with a
  kernel-enforced runtime writeability probe against the already opened file
  object. An actually writable config, including an owner-writable config, is
  still rejected; broader mode bits are accepted only when the runtime cannot
  open that object for writing, including on a read-only mount.
- Opens file-mode sources with `O_NOFOLLOW`, retains the
  `Lstat`/open/`fstat`/`SameFile` identity checks, fails closed on an
  indeterminate probe, and gives Xray the same read-only descriptor over stdin
  for semantic validation and PID 1 execution.
- Adds Linux regressions for owner and group/other writeability, read-only
  files, symlinks, directories/devices/sockets/FIFOs, oversize input,
  replacement races, probe side effects, and unexpected probe errors. The
  actual-image suite now checks both a truly writable RW bind mount rejection
  and writable mode bits on a kernel-enforced read-only bind mount acceptance.
- Records the 2026-08-16 hardware acceptance of the immutable `0.2` RC on a
  MikroTik L009 running RouterOS 7.23.3. Version, read-only file mode,
  same-source read-write rejection, actual run lifecycle, and graceful stop all
  passed, resolving the blocker found in RC `0.1`. Hardware acceptance is
  satisfied; final publication/promotion remains separately owner-gated. See
  [the detailed evidence](docs/HARDWARE-ACCEPTANCE.md).

## v0.1

- Initial generic `linux/arm64` scratch runtime for Xray `26.7.28`.
- Adds the static `xray-entry` wrapper with file, typed template, and base64
  configuration modes.
- Adds verified official release-artifact acquisition, actual-image tests, and
  non-publishing CI plus guarded tag-only release automation.
- Hardens deterministic CA sourcing, explicit final-file copying, `/tmp`
  permissions, non-writable traversable runtime directories, allowlisted
  archive extraction, strict JSON/source handling, environment scrubbing, and
  fail-closed release publication checks.
- Updates the fully pinned checkout action to the Node.js 24-based v7.0.1
  release after direct verification of its official tag commit.
- Adds a separately gated, tag-to-commit-bound RouterOS hardware-acceptance RC
  workflow. It builds and tests one `linux/arm64` image, authenticates only
  after the full suite, refuses overwrite, and publishes only an immutable
  SHA-bearing RC tag with post-push digest and platform verification.
- Makes `.env`'s `WRAPPER_RELEASE` the machine-validated wrapper-version
  authority and documents that RC publication is neither final promotion nor
  authorization for releases, deployments, other images, or secret changes.
