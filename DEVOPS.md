# Local validation

No normal command below logs in or pushes an image. Docker must have ARM64
emulation available when the host is not ARM64.

```sh
# Source checks (requires Go 1.24)
gofmt -w cmd/xray-entry
go vet ./...
go test ./...

# Build and load the candidate locally; this is not a publication.
docker buildx build --platform linux/arm64 --load -t local/xray:26.7.28-0.1-arm64 .

# Run mode, stdin-lifecycle, XHTTP, identity, and final-filesystem checks.
IMAGE=local/xray:26.7.28-0.1-arm64 bash test/integration/run.sh

# Inspect image metadata and exactly the final filesystem.
docker image inspect local/xray:26.7.28-0.1-arm64
cid=$(docker create local/xray:26.7.28-0.1-arm64)
docker export "$cid" | tar -tvf -
docker rm "$cid"

# Check the exact embedded Xray version without adding any runtime tools.
docker run --rm --platform linux/arm64 --entrypoint /usr/local/bin/xray local/xray:26.7.28-0.1-arm64 version
```

Human release procedure: review the candidate and CI results, complete RouterOS
hardware acceptance, create an approved `v<major>.<minor>` Git tag, then allow
the tag-triggered workflow to publish the immutable versioned tag. Never use
`latest`.
