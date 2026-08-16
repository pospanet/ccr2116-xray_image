# Local validation

No normal command below logs in or pushes an image. Docker must have ARM64
emulation available when the host is not ARM64. The integration inspection
also requires Bash, GNU tar/find/base64, jq, grep, and readelf on the host.

```sh
# Source checks (requires Go 1.24)
gofmt -w cmd tools
go vet ./...
go test ./...

# Build and load the candidate locally; this is not a publication.
docker buildx create --name xray-arm64 --driver docker-container --driver-opt image=moby/buildkit@sha256:0168606be2315b7c807a03b3d8aa79beefdb31c98740cebdffdfeebf31190c9f --use
docker buildx inspect --bootstrap
docker buildx build --platform linux/arm64 --provenance=false --sbom=false --load -t local/xray:26.7.28-0.2-arm64 .

# Run mode, stdin-lifecycle, XHTTP, identity, and final-filesystem checks.
IMAGE=local/xray:26.7.28-0.2-arm64 bash test/integration/run.sh

# Inspect image metadata and exactly the final filesystem.
docker image inspect local/xray:26.7.28-0.2-arm64
cid=$(docker create --platform linux/arm64 local/xray:26.7.28-0.2-arm64)
docker export "$cid" | tar -tvf -
docker rm "$cid"

# Check the exact embedded Xray version without adding any runtime tools.
docker run --rm --platform linux/arm64 --entrypoint /usr/local/bin/xray local/xray:26.7.28-0.2-arm64 version
```

## RouterOS hardware-acceptance RC

After the intended source commit and ordinary CI are reviewed, derive the only
valid RC trigger from that commit (do not use a dirty working tree):

```sh
test -z "$(git status --porcelain)"
full_sha=$(git rev-parse HEAD)
short_sha=$(git rev-parse --short=12 HEAD)
test "$full_sha" = "$(git rev-parse HEAD^{commit})"
printf 'RC Git tag: rc-v0.2-%s\n' "$short_sha"
printf 'RC image: pospa/xray-core:26.7.28-0.2-rc-%s-arm64\n' "$short_sha"
```

Only a pushed tag exactly matching `rc-v0.2-<first-12-commit-hex>` invokes
`.github/workflows/release-candidate-xray.yaml`. The workflow verifies that the
tag release equals `.env`'s `WRAPPER_RELEASE` and that its lowercase SHA suffix
matches the actual source commit. It builds and tests one local ARM64 candidate,
authenticates only after all tests, refuses an existing or indeterminate remote
tag, and publishes exactly one immutable RC tag. It creates no GitHub release
or prerelease and performs no deployment.

After publication, use the reported manifest digest for RouterOS acceptance.
Do not repoint or overwrite the RC tag. Final promotion/release is intentionally
undefined until hardware acceptance is complete and requires a separate owner
decision. Never use `latest` or another floating tag.

Human final-release procedure remains separately gated: after RouterOS hardware
acceptance and an explicit final-release decision, create the approved
`v<major>.<minor>` Git tag and allow the final tag-triggered workflow to publish
the immutable versioned tag.

### Current hardware gate

The historical `0.1` RC passed the ARM64 runtime smoke test on L009 / RouterOS
7.23.3, including `version` with exit status 0. File-mode acceptance then found
that RouterOS keeps writable Unix mode bits visible on a USB ext4 config even
when its container bind mount is `mode=ro`; the old bit-only policy rejected
that effectively read-only file. RC `0.1` must not be promoted to final.

Wrapper `0.2` tests kernel-enforced runtime writeability instead. The automated
actual-image suite must reject a mode-`0666` config on an RW bind mount and
accept the same file on an RO bind mount. L009 acceptance must repeat `version`,
file-mode `test`, and the real run lifecycle using the RouterOS `mode=ro` USB
ext4 mount. Final release remains unauthorized until that acceptance succeeds
and the owner makes a separate final-release decision.
