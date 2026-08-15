# Changelog

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
