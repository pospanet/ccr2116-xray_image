# pospa/xray-core

`pospa/xray-core:26.7.28-0.2-arm64` is the intended generic `linux/arm64` Xray runtime
image. It is not a deployment configuration: it contains no server/client
role, hostname, port, IP, UUID, XHTTP path, WireGuard setting, credential, or
CCR2116/L009 knowledge. Supply a configuration at deployment time.

## Image and configuration

The final image is `scratch`-based and contains Xray, a static `xray-entry`,
the official Xray geodata, a CA bundle, and `/tmp`. It runs as `65532:65532`,
has no shell, package manager, downloader, or debugging tools, and uses
`xray-entry` as its entrypoint.

Use exactly one explicit configuration mode:

- `file` (default): mount a persistent config at `/etc/xray/config.json`, or
  pass `--config /mounted/config.json`. This is the production preference.
  Mount it read-only. The wrapper rejects non-regular, symlink, oversize, or
  actually runtime-writable sources. It opens with `O_NOFOLLOW`, checks
  `Lstat`/open/`fstat` identity, and performs an `O_WRONLY`-only probe through
  the already opened descriptor; the probe neither creates, truncates, nor
  writes. Permission bits are not treated as kernel access results: broad bits
  are accepted on a kernel-enforced read-only mount, while owner, ACL, or
  group/other write access that lets runtime user `65532` open the object for
  writing is rejected. Unexpected probe results fail closed.
  Keep the backing inode stable during startup and do not expose the same inode
  to the container through a second writable alias; an open descriptor prevents
  pathname replacement but cannot freeze host-side in-place writes or discover
  every alias in the mount namespace.
- `template`: mount a structural JSON template and a strict JSON values object:
  `run --mode template --template /mounted/template.json --values /mounted/values.json`.
  A marker must be the whole value, e.g. `{"$xrayParam":"listen_port"}`. Types
  are preserved; there is no textual substitution.
- `env-base64`: set `XRAY_CONFIG_BASE64` to standard base64 JSON and use
  `run --mode env-base64`. This is for compatibility/automation, not
  secret-bearing production configs: container environment metadata can be
  observable to the runtime or other operators.

For file mode, the descriptor checked and parsed by the wrapper is also rewound
and passed to the pinned Xray binary through stdin for semantic validation and
PID 1 execution, so Xray does not repeat a lookup of the caller-controlled
source path. For generated modes the wrapper creates a private, unlinked `0600`
temporary file, validates the exact bytes via stdin, rewinds the same
descriptor, and execs Xray with it as stdin. Generated config transport does
not use a shell, memfd, or `/proc/self/fd`; `/proc/self/fd` is used only to ask
the kernel whether the already opened file-mode object can be reopened
`O_WRONLY`. `run` and `test` never print configuration contents or parameter
values. `uuid` intentionally prints only the newly requested UUID.

## Supply chain and versions

The image uses the official `XTLS/Xray-core` `v26.7.28` release artifact
`Xray-linux-arm64-v8a.zip`, not the upstream Docker image and not a source
compilation. BuildKit verifies its committed SHA-256
`f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501` before
extraction; only Xray and the geo data are copied from it. The matching tag
commit is `5ca6f4b7d4dc20a881d4330e498892697627ec0c`.
The CA bundle comes from the digest-pinned Go builder image; the build does not
install a moving CA package. Every runtime file is copied explicitly.

The Xray upstream version and wrapper release stay separate. `WRAPPER_RELEASE`
in `.env` is the machine-validated authority for the wrapper version:
`<image>:<xray-version>-<wrapper-release-without-v>-arm64`. Thus the current
wrapper `v0.2` maps to `pospa/xray-core:26.7.28-0.2-arm64` without changing
upstream Xray. No floating tag, including `latest`, is built or published.

See [DEVOPS.md](DEVOPS.md) for local validation commands. CI builds and tests a
locally loaded ARM64 candidate on pushes and pull requests without registry
authentication. The tag-only release workflow tests one candidate before it
logs in and publishes that same image.

RouterOS hardware acceptance may use only the dedicated immutable RC path. A
tag `rc-v0.2-<first-12-commit-hex>` triggers the RC workflow, which verifies the
tag against both `WRAPPER_RELEASE` and the actual source SHA before building.
It publishes only
`pospa/xray-core:26.7.28-0.2-rc-<first-12-commit-hex>-arm64`, after the full
actual-image suite passes, and refuses overwrite. This is not a final release,
does not create a GitHub release/prerelease, and does not deploy the image.

RC `0.2` passed the actual-image CI suite and the complete MikroTik L009 /
RouterOS 7.23.3 ARM64 hardware matrix on 2026-08-16. The matrix proved the
read-only file-mode regression, same-source read-write rejection, actual run
lifecycle, and graceful stop. The RouterOS blocker found in RC `0.1` is
resolved. See [the hardware acceptance evidence](docs/HARDWARE-ACCEPTANCE.md)
for the exact candidate, CI runs, hardware observations, and test results.

**RC 0.2 hardware acceptance: PASS.** The hardware gate is satisfied, but final
publication/promotion still requires explicit owner approval. No final release
is represented by this repository state.
