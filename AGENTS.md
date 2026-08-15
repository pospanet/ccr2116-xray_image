# Repository engineering rules

These rules apply to every change in this repository. Security invariants take
priority over convenience. If a requested change would violate an invariant,
stop, explain the conflict, and obtain an explicit design decision before
continuing.

## Current phase gate

- The owner approved the `PLAN.md` v0.1 architecture on 2026-08-15 and
  authorized implementation, local builds, tests, and image inspection.
- Do not push an image, log in to Docker Hub, create a Git tag or release,
  modify secrets, or deploy to any environment without a separate explicit
  instruction.

## Approved v0.1 baseline

- Xray input is only official `XTLS/Xray-core` `v26.7.28`, commit
  `5ca6f4b7d4dc20a881d4330e498892697627ec0c`, asset
  `Xray-linux-arm64-v8a.zip`, SHA-256
  `f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501`.
- The first image identity is `pospa/xray-core:26.7.28-0.1-arm64`; never use
  `latest`. The initial platform is only `linux/arm64`.
- The approved final filesystem is Xray, static `xray-entry`, CA bundle,
  verified release geodata, and writable `/tmp`; final stage is `scratch`.
- `xray-entry` supports only `run`, `test`, `version`, and `uuid`. Configuration
  modes are explicit `file`, structural typed `template`, and `env-base64`.
- Generated configuration uses the approved unlinked `/tmp` file and stdin
  lifecycle; no memfd or `/proc/self/fd` design is permitted.

## Product boundary

- Build one generic OCI image. It must not encode a device, network topology,
  server/client role, IP address, port, hostname, path, identity, or credential.
- Canonical production configuration is an externally mounted persistent file.
  Template and base64 modes are optional bootstrap transports, not a reason to
  bake configuration into an image.
- The initial target is `linux/arm64`, with RouterOS compatibility treated as a
  first-class constraint without making the image RouterOS-specific.
- Do not add convenience tools, a shell, a health-check client, or an init
  system to the runtime image.

## Runtime security invariants

- The final image is scratch-style and shell-less.
- The final image must not contain `/bin/sh`, Bash, BusyBox, curl, wget, SSH,
  package managers, general debugging utilities, or a dynamic loader that is
  not explicitly required and reviewed.
- Run as numeric `65532:65532`. Do not switch to root or add capabilities unless
  a documented design review proves it unavoidable.
- Do not add secrets to source, Git history, image layers, build arguments,
  image environment metadata, logs, examples, fixtures copied into the image,
  or CI artifacts.
- Never print configuration contents or parameter values. Error messages may
  identify a parameter name or source path, but not its value.
- Do not invoke a shell from Go. Construct argument vectors explicitly and use
  direct process execution. The successful `run` path must exec Xray as PID 1.
- Fail closed on ambiguity, missing inputs, malformed data, validation failure,
  unsafe file types, or permissions that cannot be made restrictive.
- Treat environment variables as observable container metadata. Do not present
  them as the preferred secret mechanism.

## Upstream and supply-chain rules

- Keep upstream Xray version and this repository's runtime release version
  separate.
- Fetch Xray only from the exact official `XTLS/Xray-core` release tag and
  artifact name recorded in `PLAN.md` (or its reviewed successor).
- Verify the archive against a full SHA-256 committed in source before
  extraction. A checksum sidecar downloaded from the same release is a useful
  cross-check, not an independent trust root.
- Copy only an explicit allowlist of files from verified upstream archives.
  Never copy an extracted directory wholesale into the final image.
- Pin builder base images by digest. Pin third-party GitHub Actions by full
  commit SHA. Review all pin updates.
- Verify the actual pinned Xray executable's CLI and reported version. Do not
  infer behavior from `main`, `latest`, or a newer release.
- GeoIP and geosite data may be included only when they are shipped inside and
  covered by the checksum of the pinned official Xray release artifact.

## Configuration and bootstrap rules

- Modes are explicit: `file`, `template`, and `env-base64`. Never silently fall
  back from one mode to another.
- Template rendering must operate on parsed JSON values. Raw text replacement,
  `sed`, `envsubst`, and shell templates are prohibited.
- Reject duplicate JSON keys, trailing data, malformed placeholders, missing
  required parameters, type mismatches, and inputs over documented size/depth
  limits.
- Rendered or decoded configuration must be held in a restrictive transient
  object and validated with the real pinned Xray binary before start.
- Do not expose a configuration-dump operation if it can reveal credentials,
  even when upstream Xray implements `run -dump`.

## Build, test, and release rules

- Ordinary pushes and pull requests validate but never authenticate to a
  registry and never publish.
- Only Git tags matching the reviewed `v*` release convention may enter the
  publishing workflow. Validate the tag strictly before login or push.
- Never create or publish a `latest` tag or any floating compatibility tag.
- The release image name is
  `<IMAGE_NAME>:<XRAY_VERSION>-<release-without-v>-arm64`.
- Refuse to overwrite an existing release tag. Record the resulting manifest
  digest and deploy a versioned, immutable reference.
- CI and release tests must inspect and execute the actual final image. A
  Dockerfile text check is not proof of runtime contents or identity.
- Test all failure paths without logging fixtures that model secrets. Keep
  canary values out of the final build context and scan the exported final
  filesystem for them.
- Keep tests deterministic, network-independent after the verified upstream
  artifact has been acquired, and runnable locally where practical.

## Change discipline

- Keep `.env` limited to non-secret build metadata. Any new field needs review.
- Preserve line endings from `.gitattributes` and keep Go code formatted.
- Update `PLAN.md` when an architectural or security decision changes. Record
  the reason, consequences, and migration or rollback effect.
- Avoid unrelated refactors. Never discard user changes or weaken a test merely
  to make CI pass.
- Treat an upstream upgrade, CA-bundle update, base-image update, wrapper change,
  and workflow change as reviewable release inputs even when only one changes.
