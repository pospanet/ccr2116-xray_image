# pospa/xray-core

`pospa/xray-core:26.7.28-0.1-arm64` is a generic `linux/arm64` Xray runtime
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
  Mount it read-only or keep it stable during startup: v0.1 intentionally
  retains a validation-to-exec TOCTOU risk for externally writable files.
- `template`: mount a structural JSON template and a strict JSON values object:
  `run --mode template --template /mounted/template.json --values /mounted/values.json`.
  A marker must be the whole value, e.g. `{"$xrayParam":"listen_port"}`. Types
  are preserved; there is no textual substitution.
- `env-base64`: set `XRAY_CONFIG_BASE64` to standard base64 JSON and use
  `run --mode env-base64`. This is for compatibility/automation, not
  secret-bearing production configs: container environment metadata can be
  observable to the runtime or other operators.

For generated modes the wrapper creates a private, unlinked `0600` temporary
file, validates the exact bytes with the pinned Xray binary via stdin, rewinds
the same descriptor, and execs Xray with it as stdin. It does not use a shell,
memfd, or `/proc/self/fd`. `run` and `test` never print configuration contents
or parameter values. `uuid` intentionally prints only the newly requested UUID.

## Supply chain and versions

The image uses the official `XTLS/Xray-core` `v26.7.28` release artifact
`Xray-linux-arm64-v8a.zip`, not the upstream Docker image and not a source
compilation. BuildKit verifies its committed SHA-256
`f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501` before
extraction; only Xray and the geo data are copied from it. The matching tag
commit is `5ca6f4b7d4dc20a881d4330e498892697627ec0c`.
The CA bundle comes from the digest-pinned Go builder image; the build does not
install a moving CA package. Every runtime file is copied explicitly.

The Xray upstream version and wrapper release stay separate:
`<image>:<xray-version>-<wrapper-release-without-v>-arm64`. Thus `v0.1` maps to
`pospa/xray-core:26.7.28-0.1-arm64`; a wrapper-only `v0.2` would map to
`26.7.28-0.2-arm64`. No floating tag, including `latest`, is built or published.

See [DEVOPS.md](DEVOPS.md) for local validation commands. CI builds and tests a
locally loaded ARM64 candidate on pushes and pull requests without registry
authentication. The tag-only release workflow tests one candidate before it
logs in and publishes that same image.
