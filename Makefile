BIN       := bin/sl
PKG       := .
VERSION   := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS   := -X main.version=$(VERSION)
SHRINK    := -s -w

PLATFORMS := darwin/arm64 darwin/amd64 linux/arm64 linux/amd64

.PHONY: build release clean cross shrink size deps publish publish-dry

# Dev build — includes debug info, fast compile.
build:
	CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o $(BIN) $(PKG)

# Stripped release build (local arch).
release:
	CGO_ENABLED=0 go build -trimpath -ldflags "$(LDFLAGS) $(SHRINK)" -o $(BIN) $(PKG)

# Cross-compile for every arch we ship. Output: dist/sl-<os>-<arch>.
cross:
	@mkdir -p dist
	@for p in $(PLATFORMS); do \
	  os=$${p%/*}; arch=$${p#*/}; \
	  out=dist/sl-$$os-$$arch; \
	  echo "  → $$out"; \
	  CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch \
	    go build -trimpath -ldflags "$(LDFLAGS) $(SHRINK)" -o $$out $(PKG) || exit 1; \
	done

# UPX-compress all binaries in dist/. Requires `brew install upx`.
shrink:
	@command -v upx >/dev/null || { echo "upx not installed — brew install upx" >&2; exit 1; }
	@for f in dist/sl-*; do upx --best --lzma $$f || true; done

size:
	@ls -lh $(BIN) dist/sl-* 2>/dev/null | awk '{printf "  %-30s %s\n", $$NF, $$5}'

deps:
	go mod tidy

# Cut a release: tag, then `make publish`. Example:
#   git tag v0.1.0 && git push --tags && make publish
# Requires: goreleaser, gh auth (for pushing to homebrew-tap).
publish:
	@command -v goreleaser >/dev/null || { echo "goreleaser not installed — brew install goreleaser" >&2; exit 1; }
	GITHUB_TOKEN=$$(gh auth token) goreleaser release --clean

# Dry run — build all artifacts into dist/ without publishing.
publish-dry:
	@command -v goreleaser >/dev/null || { echo "goreleaser not installed — brew install goreleaser" >&2; exit 1; }
	goreleaser release --snapshot --clean

clean:
	rm -rf bin dist
