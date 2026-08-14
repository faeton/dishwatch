BIN       := bin/sl
# What app/Makefile embeds in the bundle. Built with -tags apphelper, which
# omits the shell-outs, the arbitrary-RPC verb and the third-party geocoder —
# see features_apphelper.go. The root Makefile never produced this, so the app
# build's prerequisite had to be built by hand.
HELPER    := bin/dishwatch-helper
PKG       := .
VERSION   := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT    := $(shell git rev-parse --short HEAD 2>/dev/null || echo none)
LDFLAGS   := -X main.version=$(VERSION) -X main.commit=$(COMMIT)
SHRINK    := -s -w

PLATFORMS := darwin/arm64 darwin/amd64 linux/arm64 linux/amd64

.PHONY: build release clean cross shrink size deps publish publish-dry helper \
        helper-universal helper-check contract sl-lock check

# Dev build — includes debug info, fast compile.
build:
	CGO_ENABLED=0 go build -ldflags "$(LDFLAGS)" -o $(BIN) $(PKG)

# The restricted engine the app bundle embeds.
helper:
	# `go build -o` refuses to overwrite a universal binary — it only clobbers
	# something it recognises as an object file, and a fat Mach-O is not one. So
	# `make helper` after `make helper-universal` dies on "already exists and is
	# not an object file", which says nothing about the actual cause.
	@rm -f $(HELPER)
	@mkdir -p $(dir $(HELPER))   # go build -o will not create the parent, and bin/ is gitignored
	CGO_ENABLED=0 go build -trimpath -tags apphelper -ldflags "$(LDFLAGS) $(SHRINK)" -o $(HELPER) $(PKG)
	@$(MAKE) --no-print-directory helper-check

# Universal build of the same thing, for the release DMG. `go build` is
# host-native, so an arm64-only helper inside a universal app means the app
# launches on an Intel Mac and the engine dies on every spawn — worse than a
# clean failure, because it looks like a dish problem.
helper-universal:
	@rm -f $(HELPER) $(HELPER).arm64 $(HELPER).amd64   # same fat-Mach-O trap
	@mkdir -p $(dir $(HELPER))
	CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -tags apphelper -ldflags "$(LDFLAGS) $(SHRINK)" -o $(HELPER).arm64 $(PKG)
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -tags apphelper -ldflags "$(LDFLAGS) $(SHRINK)" -o $(HELPER).amd64 $(PKG)
	lipo -create -output $(HELPER) $(HELPER).arm64 $(HELPER).amd64
	@rm -f $(HELPER).arm64 $(HELPER).amd64
	@$(MAKE) --no-print-directory helper-check
	@echo "  arches: $$(lipo -archs $(HELPER))"

helper-check:
	@strings -a $(HELPER) | grep -q networkQuality \
	  && { echo "  ERROR: apphelper build still contains networkQuality" >&2; exit 1; } \
	  || echo "  $(HELPER)  (no shell-outs, no geocoder)"

# Go json tags vs Swift CodingKeys, plus the schema version on both sides.
contract:
	@./scripts/check-contract.sh

# The bash fallback's state lock, on whatever platform this is. `go test` never
# touches the bash script, so both times the lock broke it broke unobserved.
sl-lock:
	@./scripts/check-sl-lock.sh

# What CI runs, minus the Swift half.
check: contract sl-lock
	gofmt -l . | grep -v '^dist/' | (! grep .) || { echo "gofmt"; exit 1; }
	go vet ./...
	go vet -tags apphelper ./...
	go test -race ./...
	GOOS=windows GOARCH=amd64 go build ./...

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
