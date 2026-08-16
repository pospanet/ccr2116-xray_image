# Hardware acceptance evidence

## RC 0.2 — MikroTik L009 — 2026-08-16

This record captures the CI, publication, and hardware observations for the
immutable RC tested on 2026-08-16. Values in this document are observed release
evidence, not a claim that the final release has been published.

### Candidate identity

| Field | Observed value |
| --- | --- |
| Source commit | `ce1f39efaafc5fb11fdfb377e0b5b36546a03507` |
| Short source SHA | `ce1f39efaafc` |
| RC Git tag | `rc-v0.2-ce1f39efaafc` |
| RC image | `pospa/xray-core:26.7.28-0.2-rc-ce1f39efaafc-arm64` |
| RouterOS-reported image ID | `c6e4084e7cd5f26012ea5d2178e1120ce6245c4abef974c1d3beb0420ca476f8` |
| Embedded Xray runtime | `Xray 26.7.28 (Xray, Penetrates Everything.) 5ca6f4b (go1.26.5 linux/arm64)` |

The RouterOS-reported image ID is recorded exactly as observed. It is not
substituted for, or represented as, an OCI registry manifest digest.

### CI and immutable RC publication evidence

Normal CI workflow [`xray-ci` run 17](https://github.com/pospanet/ccr2116-xray_image/actions/runs/31942934079),
run ID `31942934079`, completed with conclusion `success` for exact commit
`ce1f39efaafc5fb11fdfb377e0b5b36546a03507`.

The actual-image suite explicitly passed:

- file, template, and env-base64 modes;
- invalid JSON and duplicate JSON key rejection;
- Xray semantic validation and the XHTTP `stream-one` fixture;
- runtime GeoIP and geosite access;
- acceptance of a non-writable config on an RW mount;
- correct handling of an unrelated owner-write mode bit;
- rejection of an actually writable config;
- acceptance of writable mode bits on a kernel-enforced RO mount;
- non-disclosure of config values in validation output;
- file-mode run and generated-config stdin lifecycles;
- exact `linux/arm64` platform and numeric runtime identity;
- generic image metadata and the exact final filesystem;
- the exact Xray version and the UUID command.

The suite ended with `integration and final-filesystem checks passed`.

The dedicated [`release-candidate-xray` run 2](https://github.com/pospanet/ccr2116-xray_image/actions/runs/31943111448),
run ID `31943111448`, completed with conclusion `success` for tag
`rc-v0.2-ce1f39efaafc` at that exact source commit. This is evidence of the RC
pipeline only; it was not a final release publication.

### Hardware and RouterOS environment

| Field | Observed value |
| --- | --- |
| Device | MikroTik `L009UiGS-2HaxD` |
| RouterOS | `7.23.3 (stable)` |
| RouterOS build time | `2026-07-30 11:17:12` |
| Architecture | `arm64` |
| CPU | ARM64, 2 cores, 800 MHz |
| RAM | 512 MiB |
| Container package | RouterOS 7.23.3 |
| Device mode | container enabled |
| Container storage | external USB ext4 `L009-DATA` |
| Container tmpdir | `/L009-DATA/tmp/containers` |

RouterOS reported the candidate's default container metadata as:

- `os="linux"`;
- `arch="arm64"`;
- `default-entrypoint="/usr/local/bin/xray-entry"`;
- `default-cmd="run"`;
- `default-user="65532:65532"`;
- `start-on-boot=no`.

### Hardware acceptance matrix

#### C1 — ARM64 version smoke test — PASS

Command: `xray-entry version`

Observed output:

```text
Xray 26.7.28 (Xray, Penetrates Everything.) 5ca6f4b (go1.26.5 linux/arm64)
```

Observed exit status: `0`.

#### C2 — RouterOS read-only file-mode regression — PASS

The source `/L009-DATA/volumes/xray/config/smoke.json` contained:

```json
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[]}
```

RouterOS mounted `/L009-DATA/volumes/xray/config` at `/config` with `mode=ro`.
The command `xray-entry test --config /config/smoke.json` produced
`*** exited with status 0`.

This is the regression that failed in wrapper release `0.1`.

#### C3 — same source on an RW mount must fail — PASS

For the same source file and container, only the mount mode was changed to
`mode=rw`. The command `xray-entry test --config /config/smoke.json` reported:

```text
xray-entry: file mode config "/config/smoke.json": source is writable by the runtime user
```

Observed exit status: `1`. The RouterOS compatibility fix therefore preserves
the security invariant: a kernel-enforced RO source is accepted, while an
actually runtime-writable source is rejected.

#### C4 — actual run lifecycle — PASS

After restoring the mount to `mode=ro`, the command
`xray-entry run --config /config/smoke.json` produced these observations:

- container state `R - RUNNING`;
- `Xray 26.7.28 ... linux/arm64`;
- `Using config from STDIN`;
- `Reading config: &{Name:stdin: Format:json}`;
- `[Warning] core: Xray 26.7.28 started`.

This demonstrates that file-mode execution on the hardware used the validated
open descriptor/stdin path rather than reopening the original config pathname.

#### C5 — graceful stop — PASS

After the RouterOS container stop operation, the observed sequence was
`*** stop`, followed by `*** exited with status 0`. The container returned to
`S - STOPPED`.

### Resource snapshot after acceptance

RouterOS `/system resource print` after the test sequence reported:

| Field | Observed value |
| --- | --- |
| uptime | `2h20m27s` |
| free-memory | `243.8MiB` |
| total-memory | `512.0MiB` |
| cpu-load | `3%` |
| free-hdd-space | `85.1MiB` |
| total-hdd-space | `128.0MiB` |
| write-sect-since-reboot | `273` |
| write-sect-total | `30696` |
| bad-blocks | `0%` |
| architecture-name | `arm64` |

No RouterOS `memory-current` or `container-size` value is treated as
authoritative process RSS.

### Acceptance conclusion and release gate

`pospa/xray-core:26.7.28-0.2-rc-ce1f39efaafc-arm64` passed source/unit
validation, actual ARM64 image CI, final-filesystem validation, the file-mode
security regression, the immutable RC publishing pipeline, real MikroTik
RouterOS 7.23.3 ARM64 execution, the read-only file-mode regression, read-write
rejection, the actual Xray run lifecycle, and graceful stop.

The RouterOS file-mode blocker found in RC `0.1` is resolved in RC `0.2`.

**RC 0.2 hardware acceptance: PASS**

**final release gate: hardware acceptance satisfied; final
publication/promotion still requires explicit owner approval.**

No final Git tag, final Docker tag, GitHub Release, deployment, or final image
publication is established by this evidence record.

### Final-release provenance recommendation

The preferred final release mechanism is to promote/re-tag the already tested
and hardware-accepted RC image digest as
`pospa/xray-core:26.7.28-0.2-arm64`, rather than independently rebuilding a new
final image. This keeps the final artifact byte-identical to the exact RC
artifact that passed CI and RouterOS hardware acceptance.

That mechanism is a release-engineering recommendation, not implemented
workflow behavior or publication authorization. It requires explicit design,
implementation, review, and owner approval before final release. In
particular, this evidence does not authorize changing or running the current
final-release workflow, publishing an image, or creating or pushing a tag.
