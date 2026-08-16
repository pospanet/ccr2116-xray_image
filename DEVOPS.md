# Local validation

No normal command below logs in or pushes an image. Docker must have ARM64
emulation available when the host is not ARM64. The integration inspection
also requires Bash, GNU tar/find/base64, jq, grep, and readelf on the host.

```sh
# Source checks (requires Go 1.24)
gofmt -w cmd tools
go vet ./...
go test ./...

# Release metadata, accepted-RC binding, and offline promotion-state tests.
bash test/validate-metadata.sh
bash test/validate-final-release.sh repository v0.2
bash test/final-release-validation-test.sh

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
Do not repoint or overwrite the RC tag. Never use `latest` or another floating
tag.

Human final-release publication remains separately gated. Creating and pushing
the exact `v<major>.<minor>` tag is the owner's explicit release action; no
repository script creates or pushes Git tags.

### Current hardware gate

The exact wrapper `0.2` candidate from commit
`ce1f39efaafc5fb11fdfb377e0b5b36546a03507`, published under immutable RC tag
`rc-v0.2-ce1f39efaafc`, passed the L009 / RouterOS 7.23.3 ARM64 hardware matrix
on 2026-08-16. The test accepted the USB ext4 config through RouterOS
`mode=ro`, rejected the same source through `mode=rw`, ran Xray through the
validated descriptor/stdin lifecycle, and stopped cleanly. The `0.1` file-mode
blocker is resolved. Exact CI and hardware observations are in
[the hardware acceptance record](docs/HARDWARE-ACCEPTANCE.md).

**RC 0.2 hardware acceptance: PASS.** Hardware acceptance is satisfied; final
publication/promotion still requires explicit owner approval.

### Final release promotion

**FINAL RELEASE IS PROMOTION, NOT REBUILD.** The repository-controlled binding
[`release/final/v0.2.env`](release/final/v0.2.env) ties wrapper `0.2` to Xray
`26.7.28`, `linux/arm64`, source commit
`ce1f39efaafc5fb11fdfb377e0b5b36546a03507`, RC Git tag
`rc-v0.2-ce1f39efaafc`, the hardware PASS record, and accepted OCI manifest
digest
`sha256:a100a4b10ef8aefb658fa9f54359839f983fcab6dbd40431780e09e36bde0ba8`.
The later documentation commit is release evidence, not runtime provenance.

Before the owner pushes `v0.2`, Docker Hub must have all-tag immutability
enabled for `pospa/xray-core` with rule `.*`. The final workflow checks that
public repository setting without credentials and fails closed if it is
disabled or indeterminate. This server-side gate closes the concurrent
check/use window as well as preventing later RC or final-tag mutation.

On `v0.2`, `.github/workflows/release-xray.yaml` performs this sequence:

1. Fetch full Git history and tags without persisting GitHub credentials.
2. Validate the final tag, `.env`, the unique accepted-RC metadata file, the
   exact RC/source Git relationship, and exact hardware PASS evidence.
3. Verify Docker Hub all-tag immutability without registry credentials.
4. Install the already pinned Buildx version, then log in to Docker Hub.
5. Resolve the RC tag and digest-pinned reference, requiring the committed
   digest and a single `linux/arm64` manifest.
6. Refuse an existing final tag with any other digest. If it already has the
   accepted digest, continue as an idempotent success without mutation.
7. Otherwise dry-run and execute `docker buildx imagetools create
   --prefer-index=false` from `pospa/xray-core@sha256:...` to the final tag.
   No Dockerfile, build, QEMU, local retag, or image push path is present.
8. Independently resolve the RC and final tags again and require both to equal
   the previously captured accepted digest.

The workflow prints only non-secret provenance, creates no GitHub Release, and
performs no deployment. A GitHub Release, if ever desired, requires a separate
reviewed design and may occur only after digest equality passes. The currently
documented repository state does not claim that `v0.2` or the final Docker tag
has been published.
