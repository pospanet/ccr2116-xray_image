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
docker buildx build --platform linux/arm64 --provenance=false --sbom=false --load -t local/xray:26.7.28-0.1-arm64 .

# Run mode, stdin-lifecycle, XHTTP, identity, and final-filesystem checks.
IMAGE=local/xray:26.7.28-0.1-arm64 bash test/integration/run.sh

# Inspect image metadata and exactly the final filesystem.
docker image inspect local/xray:26.7.28-0.1-arm64
cid=$(docker create --platform linux/arm64 local/xray:26.7.28-0.1-arm64)
docker export "$cid" | tar -tvf -
docker rm "$cid"

# Check the exact embedded Xray version without adding any runtime tools.
docker run --rm --platform linux/arm64 --entrypoint /usr/local/bin/xray local/xray:26.7.28-0.1-arm64 version
```

Human release procedure: review the candidate and CI results, complete RouterOS
hardware acceptance, create an approved `v<major>.<minor>` Git tag, then allow
the tag-triggered workflow to publish the immutable versioned tag. Never use
`latest`.
