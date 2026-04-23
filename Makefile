BIN       := bin/sl
PKG       := .
VERSION   := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS   := -X main.version=$(VERSION)
SHRINK    := -s -w -buildid=
TAGS      := netgo,osusergo,grpcnotrace

PLATFORMS := darwin/arm64 darwin/amd64 linux/arm64 linux/amd64

.PHONY: build release clean cross shrink size deps

# Dev build — includes debug info, fast compile.
build:
	CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o $(BIN) $(PKG)

# Stripped release build (local arch). After the linker strips debug info
# we run `strip -x` on darwin to drop local symbols too (notarization-safe).
release:
	CGO_ENABLED=0 go build -trimpath -tags "$(TAGS)" -ldflags "$(LDFLAGS) $(SHRINK)" -o $(BIN) $(PKG)
	@if [ "$$(uname)" = "Darwin" ]; then strip -x $(BIN); fi

# Cross-compile for every arch we ship. Output: dist/sl-<os>-<arch>.
cross:
	@mkdir -p dist
	@for p in $(PLATFORMS); do \
	  os=$${p%/*}; arch=$${p#*/}; \
	  out=dist/sl-$$os-$$arch; \
	  echo "  → $$out"; \
	  CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch \
	    go build -trimpath -tags "$(TAGS)" -ldflags "$(LDFLAGS) $(SHRINK)" -o $$out $(PKG) || exit 1; \
	  if [ "$$os" = "darwin" ] && command -v strip >/dev/null; then strip -x $$out 2>/dev/null || true; fi; \
	done

# UPX-compress all binaries in dist/. Requires `brew install upx`.
shrink:
	@command -v upx >/dev/null || { echo "upx not installed — brew install upx" >&2; exit 1; }
	@for f in dist/sl-*; do upx --best --lzma $$f || true; done

size:
	@ls -lh $(BIN) dist/sl-* 2>/dev/null | awk '{printf "  %-30s %s\n", $$NF, $$5}'

deps:
	go mod tidy

clean:
	rm -rf bin dist
