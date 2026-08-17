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
        helper-universal helper-check contract sl-lock check site site-dry \
        cask cask-dry

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

# Publish site/index.html to the Pages repo.
#
# site/index.html is the source of truth; dishwatch.github.io holds a copy and
# nothing but this target keeps them equal. That copy used to be made by hand,
# which is how the landing page came to advertise a panel the app had stopped
# shipping — so if you edit the site, finish with `make site`.
#
# Deliberately a command you run, not a push hook: a website going live is a
# decision, and every merge to main is not.
SITE_REPO ?= git@github.com:dishwatch/dishwatch.github.io.git
SITE_WORK ?= $(CURDIR)/dist/site

# Show what would be published, changing nothing remote. The checkout is reset
# to origin first — it persists across runs, so without this a copy left over
# from a previous `make site` would diff against a stale base.
site-dry: $(SITE_WORK)
	@cd $(SITE_WORK) && git fetch -q origin && git reset -q --hard origin/main
	@cp site/index.html $(SITE_WORK)/index.html
	@cd $(SITE_WORK) && if git diff --quiet; then echo "  site already up to date"; \
	  else git --no-pager diff --stat; fi

site: site-dry
	@cd $(SITE_WORK) && if git diff --quiet; then exit 0; fi; \
	  git add index.html && \
	  git commit -q -m "Sync landing page from dishwatch@$$(cd $(CURDIR) && git rev-parse --short HEAD)" && \
	  git push -q origin main && echo "  published to https://dishwatch.github.io"

$(SITE_WORK):
	@mkdir -p $(dir $(SITE_WORK))
	git clone -q $(SITE_REPO) $(SITE_WORK)

# Publish packaging/dishwatch-app.rb into the tap as Casks/dishwatch-app.rb,
# with the version and DMG sha of a release that already exists.
#
# This was a hand-copy step, and v0.2.6 shipped without it. Nothing failed at
# release time; instead the tap's nightly `brew audit --cask --online --strict`
# started failing, because livecheck resolved 0.2.6 while the cask still said
# 0.2.5 — a daily red build for a mistake made once, days earlier.
#
# It cannot fold into `make publish`: goreleaser only maintains taps for
# artifacts it built, and the DMG comes from app/Makefile via two notarization
# round-trips. So the order is `make publish` → upload the DMG → `make cask`,
# and the sha is read back from the release rather than from any local file, so
# what the cask promises is what a user actually downloads.
CASK_REPO ?= git@github.com:faeton/homebrew-tap.git
CASK_WORK ?= $(CURDIR)/dist/tap
# Lazy on purpose — `?=` keeps this a recursive variable, so unrelated targets
# never pay for the API call. Override as `make cask CASK_TAG=v0.2.6`.
CASK_TAG  ?= $(shell gh release view --json tagName --jq .tagName 2>/dev/null)

# Show what would be published, changing nothing remote. Same reset-first
# reasoning as site-dry: the checkout persists between runs.
cask-dry: $(CASK_WORK)
	@cd $(CASK_WORK) && git fetch -q origin && git reset -q --hard origin/main
	@tag="$(CASK_TAG)"; \
	  test -n "$$tag" || { echo "  ERROR: no published release found — pass CASK_TAG=vX.Y.Z" >&2; exit 1; }; \
	  ver=$${tag#v}; dmg="DishWatch-$$ver.dmg"; \
	  sha=$$(gh release download "$$tag" -p checksums.txt -O - | awk -v d="$$dmg" '$$2 == d {print $$1}'); \
	  test -n "$$sha" || { echo "  ERROR: $$dmg is not in $$tag checksums.txt — is the DMG uploaded?" >&2; exit 1; }; \
	  sed -e "s|^  version \".*\"$$|  version \"$$ver\"|" \
	      -e "s|^  sha256 \".*\"$$|  sha256 \"$$sha\"|" \
	      packaging/dishwatch-app.rb > $(CASK_WORK)/Casks/dishwatch-app.rb; \
	  grep -q "^  version \"$$ver\"$$" $(CASK_WORK)/Casks/dishwatch-app.rb && \
	  grep -q "^  sha256 \"$$sha\"$$" $(CASK_WORK)/Casks/dishwatch-app.rb || \
	    { echo "  ERROR: packaging/dishwatch-app.rb no longer has the version/sha256 lines this rewrites" >&2; exit 1; }
	@cd $(CASK_WORK) && if git diff --quiet; then echo "  cask already at $(CASK_TAG)"; \
	  else git --no-pager diff -- Casks/dishwatch-app.rb; fi

# The version comes back out of the rendered file rather than from a second
# `gh release view`, so the commit message cannot disagree with what it commits.
cask: cask-dry
	@cd $(CASK_WORK) && if git diff --quiet; then exit 0; fi; \
	  ver=$$(awk -F'"' '/^  version /{print $$2}' Casks/dishwatch-app.rb); \
	  git add Casks/dishwatch-app.rb && \
	  git commit -q -m "DishWatch app cask $$ver" && \
	  git push -q origin main && echo "  published cask $$ver to faeton/homebrew-tap"

$(CASK_WORK):
	@mkdir -p $(dir $(CASK_WORK))
	git clone -q $(CASK_REPO) $(CASK_WORK)

clean:
	rm -rf bin dist
