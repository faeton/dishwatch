# Assembles DishWatch.app around the SwiftPM binary.
#
# Why a Makefile and not an Xcode project or xcodegen: the app is one
# executable target with no storyboards, no build phases and no dependencies,
# so a project file would be several hundred lines of generated XML whose only
# job is to copy three files and run codesign. This does that in a form you can
# read and diff. If the app ever grows a widget extension, an XPC service or a
# second target, that trade flips — revisit it then, not now.
#
#   make app                 → build, assemble, ad-hoc sign (sandboxed)
#   make app SANDBOX=0       → same, unsandboxed — the Phase 2 spike's control
#   make app CODESIGN_ID=... → sign with a real identity
#   make run                 → build and launch it
#   make icon                → regenerate AppIcon.icns from the app's own glyph
#   make clean-app

APP        := DishWatch
BUNDLE_ID  := com.faeton.dishwatch

# Release, and this is not a detail. Building `-c debug` meant every `#if DEBUG`
# block written to keep development scaffolding *out* of a shipped app was
# compiled *into* it — including HelperProvider's DISHWATCH_BIN lookup, whose own
# comment says it must never reach a release build because a shipped app that
# goes looking through the environment for its helper can be pointed at an
# arbitrary binary. `make icon` still needs a debug build; it overrides below.
CONFIG     := release
BUILD_DIR  := .build/$(CONFIG)
APP_DIR    := .build/$(APP).app
CONTENTS   := $(APP_DIR)/Contents

# `git describe` gives 0.1.0-3-gabc123 style strings. CFBundleShortVersionString
# must be dot-separated digits or the installer and App Store Connect both
# reject it, so strip a leading v and everything from the first dash.
VERSION    := $(shell git describe --tags --always --dirty 2>/dev/null || echo 0.0.0)
SHORT_VER  := $(shell echo "$(VERSION)" | sed -E 's/^v//; s/-.*//; s/^[^0-9].*/0.0.0/')
# Monotonic build number. Commit count is the cheapest thing that only ever
# goes up, which is all the Store requires of it.
BUILD_NUM  := $(shell git rev-list --count HEAD 2>/dev/null || echo 0)

# The engine that ships inside the bundle. Built with `-tags apphelper`, which
# omits `speed` (exec's ping and networkQuality), `raw` (arbitrary gRPC) and the
# Nominatim geocoder — none of which the app invokes, all of which were
# previously submitted to review inside the nested binary because this used to
# copy the full CLI. Verify with:
#     strings Contents/MacOS/dishwatch-helper | grep -c networkQuality   # → 0
HELPER_SRC ?= ../bin/dishwatch-helper

SANDBOX    ?= 1
ifeq ($(SANDBOX),1)
ENTITLEMENTS := Resources/$(APP).entitlements
else
ENTITLEMENTS := Resources/$(APP)-nosandbox.entitlements
endif

# Ad-hoc by default. That is enough to make the sandbox and TCC real on this
# machine, which is what the spike needs; it is not enough to distribute.
CODESIGN_ID ?= -

# A secure timestamp is mandatory for notarization — a bundle signed
# `--timestamp=none` is rejected with "The signature does not include a secure
# timestamp", after the upload, which is a slow way to find out. It was
# hardcoded off here because it costs a round-trip to Apple's TSA on every
# build and an ad-hoc signature cannot carry one anyway. So: off for ad-hoc,
# on for every real identity. Getting this backwards is invisible until you
# notarize, since `codesign --verify` passes either way.
ifeq ($(CODESIGN_ID),-)
TIMESTAMP := --timestamp=none
else
TIMESTAMP := --timestamp
endif

# Where notarytool finds its App Store Connect credentials.
#
# The name is a local keychain nickname, not anything Apple issues, and the
# credential is per-account rather than per-project — so this points at the
# profile another project on this machine already created and validated, rather
# than a second one holding the same Apple ID and app-specific password. Create
# an equivalent on a fresh machine with:
#   xcrun notarytool store-credentials <any-name> \
#     --apple-id <you@example.com> --team-id $(EXPECTED_TEAM_ID) --password <app-specific>
NOTARY_PROFILE ?= porter-notarization
# `override` on purpose: this is what we assert the signature says, so it must
# not be settable from the command line. A user-overridable expectation is not
# an assertion — TEAM_ID=WHATEVER would have made the check agree with whatever
# it was handed.
override EXPECTED_TEAM_ID := BKY9R5336T
DMG            := .build/$(APP)-$(SHORT_VER).dmg
ZIP            := .build/$(APP)-$(SHORT_VER).zip

# The helper's entitlements depend on whether the app is sandboxed, and getting
# this wrong is fatal rather than degraded. `com.apple.security.inherit` means
# "adopt my parent's sandbox"; with an unsandboxed parent there is nothing to
# adopt, so libsecinit aborts the child in its initializer — EXC_BREAKPOINT
# before main(), no output, no error the app can catch. `make app SANDBOX=0`
# built exactly that: the app came up fine and the helper died on every spawn,
# which reads as a dish problem rather than a packaging one. Measured: 5 crash
# reports in ~30s of retries.
ifeq ($(SANDBOX),1)
HELPER_ENTITLEMENTS := --entitlements Resources/helper.entitlements
else
HELPER_ENTITLEMENTS :=
endif

# Release artifacts are universal. `swift build` and `go build` are both
# host-native by default, so the DMG built on this arm64 laptop simply will not
# run on the Intel Macs that macOS 14 still supports — and it fails as "app is
# damaged", which reads like a signing fault. Dev builds stay host-only; only
# the release path pays the double build.
UNIVERSAL   ?= 0
# Which root-Makefile target builds an engine matching this bundle's shape.
HELPER_TARGET := $(if $(filter 1,$(UNIVERSAL)),helper-universal,helper)
ifeq ($(UNIVERSAL),1)
SWIFT_ARCH    := --arch arm64 --arch x86_64
# Capitalised, and a different tree entirely, when SwiftPM is given --arch.
SWIFT_PRODUCT := .build/apple/Products/$(shell echo $(CONFIG) | awk '{print toupper(substr($$0,1,1)) substr($$0,2)}')/$(APP)
else
SWIFT_ARCH    :=
SWIFT_PRODUCT := $(BUILD_DIR)/$(APP)
endif

.PHONY: app run icon clean-app test dmg notarize notarize-app verify-release \
        check-identity check-version

# Always reassembles rather than treating $(APP_DIR) as a file target. A
# directory target compares mtimes against sources, which is wrong here in a way
# that costs real debugging time: SANDBOX and CODESIGN_ID change the *output*
# without touching any prerequisite, so `make app SANDBOX=0` after `make app`
# would print "sandbox=0" and hand you back the sandboxed bundle. Assembling is
# a copy and a codesign — cheap enough that caching it buys nothing and can lie.
app:
	swift build -c $(CONFIG) $(SWIFT_ARCH)
	rm -rf "$(APP_DIR)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	# A multi-arch `swift build` writes to .build/apple/Products/<Config>/,
	# not .build/<config>/ — so $(BUILD_DIR) is wrong precisely when it matters.
	cp "$(SWIFT_PRODUCT)" "$(CONTENTS)/MacOS/$(APP)"
	# The engine. A sandboxed app cannot reach a CLI installed outside its
	# bundle, so this is not a convenience — it is the only path that works for
	# the Store build.
	@test -x "$(HELPER_SRC)" || { echo "  missing $(HELPER_SRC) — run: (cd .. && go build -tags apphelper -o bin/dishwatch-helper .)" >&2; exit 1; }
	cp "$(HELPER_SRC)" "$(CONTENTS)/MacOS/dishwatch-helper"
	# Refuse to ship a helper built without the apphelper tag. The two binaries
	# are byte-similar enough that a packaging slip is invisible by eye, and the
	# consequence — networkQuality, arbitrary gRPC and a third-party geocoder
	# inside the submission — is exactly what the tag exists to prevent.
	@if strings -a "$(CONTENTS)/MacOS/dishwatch-helper" | grep -q networkQuality; then \
	  echo "  ERROR: helper contains networkQuality — rebuild with -tags apphelper" >&2; exit 1; fi
	# The helper is copied from a separate build tree, so UNIVERSAL=1 says
	# nothing about it. A universal app around an arm64-only helper is the worst
	# of both: it launches on an Intel Mac and then the engine dies on every
	# spawn, which presents as a dish fault. This build produced exactly that
	# before the check existed — `make helper` had last written a host-only
	# binary and nothing noticed.
	@if [ "$(UNIVERSAL)" = "1" ]; then \
	  archs="$$(lipo -archs "$(CONTENTS)/MacOS/dishwatch-helper")"; \
	  case "$$archs" in \
	    *arm64*x86_64*|*x86_64*arm64*) ;; \
	    *) echo "  ERROR: UNIVERSAL=1 but the helper is '$$archs' — run: (cd .. && make helper-universal)" >&2; exit 1;; \
	  esac; \
	  archs="$$(lipo -archs "$(CONTENTS)/MacOS/$(APP)")"; \
	  case "$$archs" in \
	    *arm64*x86_64*|*x86_64*arm64*) ;; \
	    *) echo "  ERROR: UNIVERSAL=1 but the app binary is '$$archs' — SwiftPM wrote a thin product" >&2; exit 1;; \
	  esac; \
	fi
	cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	cp Resources/PrivacyInfo.xcprivacy "$(CONTENTS)/Resources/PrivacyInfo.xcprivacy"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(SHORT_VER)" "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUM)" "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	# --force because the SwiftPM binary may already carry an ad-hoc signature
	# from the linker; without it codesign refuses rather than replacing.
	# Nested code first, inside-out, or the outer seal covers a stale hash.
	# When the app is sandboxed the helper gets `inherit` rather than the app's
	# own entitlements: Apple's embedded-tool rule is that a child inherits the
	# parent's sandbox, and handing it an independent profile breaks that. When
	# the app is NOT sandboxed it gets no entitlements at all — see
	# HELPER_ENTITLEMENTS above for why `inherit` is fatal there.
	codesign --force --sign "$(CODESIGN_ID)" \
	         $(HELPER_ENTITLEMENTS) \
	         --options runtime $(TIMESTAMP) \
	         "$(CONTENTS)/MacOS/dishwatch-helper"
	codesign --force --sign "$(CODESIGN_ID)" \
	         --entitlements "$(ENTITLEMENTS)" \
	         --options runtime \
	         $(TIMESTAMP) \
	         "$(APP_DIR)"
	codesign --verify --deep --strict "$(APP_DIR)"
	@echo "  $(APP_DIR)  $(SHORT_VER) ($(BUILD_NUM))  sandbox=$(SANDBOX)  id=$(CODESIGN_ID)"
	@echo "  entitlements actually in the signature:"
	@codesign -d --entitlements - --xml "$(APP_DIR)" 2>/dev/null | plutil -p - | sed 's/^/    /'

run: app
	@pkill -x $(APP) 2>/dev/null || true
	open "$(APP_DIR)"

# Regenerates the icon from DishArcGlyph via the render harness, so the app
# icon and the menu-bar glyph share a source. Checked in, because building the
# app should not require running the app.
# Deliberately debug: the render harness this drives is behind `#if DEBUG`, so a
# release build has no DISHWATCH_APPICON path to invoke. That is the point — it
# is a build-time tool, not a runtime feature of the shipped app.
icon: CONFIG := debug
icon: BUILD_DIR := .build/debug
icon:
	swift build -c $(CONFIG)
	@rm -rf .build/AppIcon.iconset && mkdir -p .build/AppIcon.iconset
	DISHWATCH_APPICON=.build/appicon-1024.png "$(BUILD_DIR)/$(APP)"
	@for sz in 16 32 64 128 256 512; do \
	  sips -z $$sz $$sz .build/appicon-1024.png --out .build/AppIcon.iconset/icon_$${sz}x$${sz}.png >/dev/null; \
	  sips -z $$((sz*2)) $$((sz*2)) .build/appicon-1024.png --out .build/AppIcon.iconset/icon_$${sz}x$${sz}@2x.png >/dev/null; \
	done
	@cp .build/appicon-1024.png .build/AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
	@ls -lh Resources/AppIcon.icns | awk '{print "  Resources/AppIcon.icns", $$5}'

test:
	swift test

# ---- direct distribution (Developer ID + notarization) ----------------------
#
# This is the path the certificates on this machine actually support. The Mac
# App Store needs a different pair of certs ("Apple Distribution" and "3rd
# Party Mac Developer Installer"), a different entitlements file carrying the
# team-injected application-identifier, and `productbuild` rather than a DMG —
# see docs/roadmap.md. Do not assume this target gets you there.
#
# ONE command, and it must carry the identity:
#
#   make notarize CODESIGN_ID="Developer ID Application: ... (TEAMID)"
#
# Not two. `make notarize` on its own re-enters `dmg` with the default ad-hoc
# identity and is refused — make does not carry command-line variables between
# invocations, so a documented two-step sequence silently loses CODESIGN_ID.

# The identity has to be a Developer ID Application cert from our team, and
# `!= "-"` does not establish that. An Apple Development or wrong-team cert
# signs and timestamps happily, then fails at the notary after the upload.
# Checked against the signed output rather than the string, so it also catches
# a codesign that quietly picked a different matching identity.
# The tag, the DMG filename and the bundle's own version are three independent
# derivations of "which release is this", and nothing compared them. SHORT_VER
# strips everything after the first dash of `git describe`, so building off an
# untagged commit yields a DMG named for the PREVIOUS tag — and it notarizes,
# uploads and installs perfectly while claiming to be a version it is not.
check-version:
	@desc="$$(git describe --tags --exact-match 2>/dev/null || true)"; \
	 if [ -z "$$desc" ]; then \
	   echo "  ERROR: HEAD is not exactly on a tag — the release version would be guessed from $$(git describe --tags --always)" >&2; \
	   echo "         tag first, then build: the DMG name and Info.plist both come from git describe" >&2; \
	   exit 1; \
	 fi; \
	 want="$${desc#v}"; \
	 if [ "$$want" != "$(SHORT_VER)" ]; then \
	   echo "  ERROR: tag $$desc gives $$want but SHORT_VER is $(SHORT_VER)" >&2; exit 1; \
	 fi; \
	 got="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(CONTENTS)/Info.plist" 2>/dev/null)"; \
	 if [ "$$got" != "$$want" ]; then \
	   echo "  ERROR: bundle says $$got, tag says $$want" >&2; exit 1; \
	 fi; \
	 echo "  version ok — tag $$desc, bundle $$got, DMG $(APP)-$(SHORT_VER).dmg"

check-identity:
	@case "$(CODESIGN_ID)" in -|"") \
	  echo "  refusing to package an ad-hoc build — pass CODESIGN_ID=\"Developer ID Application: ...\"" >&2; \
	  exit 1;; esac
	# Every assertion applies to BOTH code objects. Checking authority and team
	# only on the outer bundle left the nested helper — which the notary inspects
	# just as closely — asserted on nothing but its timestamp.
	@for b in "$(APP_DIR)" "$(CONTENTS)/MacOS/dishwatch-helper"; do \
	  codesign --verify --strict "$$b" \
	    || { echo "  ERROR: $$b has an invalid signature" >&2; exit 1; }; \
	  meta="$$(codesign -dvv "$$b" 2>&1)"; \
	  printf '%s\n' "$$meta" | grep -q "^Authority=Developer ID Application:" \
	    || { echo "  ERROR: $$b is not signed by a Developer ID Application cert — the notary will reject it" >&2; exit 1; }; \
	  printf '%s\n' "$$meta" | grep -q "^TeamIdentifier=$(EXPECTED_TEAM_ID)$$" \
	    || { echo "  ERROR: $$b is not team $(EXPECTED_TEAM_ID)" >&2; exit 1; }; \
	  printf '%s\n' "$$meta" | grep -q "^Timestamp=" \
	    || { echo "  ERROR: $$b carries no secure timestamp — the notary would reject this" >&2; exit 1; }; \
	  printf '%s\n' "$$meta" | grep -qE "^CodeDirectory .*flags=.*runtime" \
	    || { echo "  ERROR: $$b is not hardened-runtime" >&2; exit 1; }; \
	done
	@echo "  identity ok — Developer ID, team $(EXPECTED_TEAM_ID), timestamped, hardened, universal=$(UNIVERSAL)"

# Stage one: notarize and staple the .app itself.
#
# Stapling only the DMG is the common shortcut and it is not enough here. The
# ticket is attached to the container the user double-clicks; once they drag the
# app to /Applications, that copy carries quarantine but no ticket, so first
# launch needs syspolicyd to fetch the ticket over the network. For an app whose
# users' internet *is* the dish — plausibly down at exactly that moment — that
# is a likely path, not an edge case. So the app gets its own ticket, and the
# DMG is built afterwards around the already-stapled app.
notarize-app:
	# The release shape is not a suggestion. UNIVERSAL defaults to 0 so dev
	# builds stay fast, which means forgetting the flag on the release command
	# silently uploads and ships an arm64-only artifact — the exact defect the
	# universal work existed to fix, reachable by omission. Likewise SANDBOX=0
	# is a diagnostic control and must never leave this machine.
	@test "$(UNIVERSAL)" = "1" || { \
	  echo "  ERROR: notarization requires UNIVERSAL=1 (an arm64-only build hard-fails on Intel)" >&2; exit 1; }
	@test "$(SANDBOX)" = "1" || { \
	  echo "  ERROR: SANDBOX=0 is a control build and must not ship" >&2; exit 1; }
	# Build the matching engine rather than asking the operator to remember a
	# second command in another directory. The thin-helper guard in `app` is
	# still worth having, but it should be catching a genuine mistake, not the
	# normal case — and it caught the normal case on the first real run.
	$(MAKE) -C .. $(HELPER_TARGET)
	$(MAKE) app CODESIGN_ID="$(CODESIGN_ID)" UNIVERSAL="$(UNIVERSAL)"
	$(MAKE) check-identity CODESIGN_ID="$(CODESIGN_ID)" UNIVERSAL="$(UNIVERSAL)"
	$(MAKE) check-version
	@rm -f "$(ZIP)"
	# ditto, not zip: it preserves the bundle's symlinks and extended
	# attributes, and the signature does not survive a naive zip.
	/usr/bin/ditto -c -k --keepParent "$(APP_DIR)" "$(ZIP)"
	xcrun notarytool submit "$(ZIP)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(APP_DIR)"
	@rm -f "$(ZIP)"
	# Stapling rewrites the bundle. Confirm it did not invalidate the seal here,
	# rather than discovering it after the DMG has been built around it.
	codesign --verify --deep --strict "$(APP_DIR)"

# Wraps whatever is currently in $(APP_DIR). Deliberately makes no claim about
# what that is — the callers below establish it.
package-dmg:
	@rm -f "$(DMG)"
	# Stage rather than pointing -srcfolder at the bundle directly. Two reasons:
	# the staging folder is where the /Applications symlink lives, so the window
	# opens with the usual drag-here pair instead of a lone icon; and it removes
	# the ambiguity both reviewers raised about whether -srcfolder on a .app
	# packages the bundle or its contents. (It packages the bundle — mounted and
	# checked — but a staging dir makes that unarguable rather than folklore.)
	@rm -rf .build/dmg-root
	@mkdir -p .build/dmg-root
	/usr/bin/ditto "$(APP_DIR)" ".build/dmg-root/$(APP).app"
	ln -s /Applications .build/dmg-root/Applications
	hdiutil create -volname "$(APP)" -srcfolder .build/dmg-root \
	  -ov -format UDZO -quiet "$(DMG)"
	@rm -rf .build/dmg-root
	# The image gets a signature but not a hardened runtime — there is no code
	# in it to harden, and passing --options runtime to a disk image is a no-op
	# that only muddies the verification output.
	codesign --force --sign "$(CODESIGN_ID)" --timestamp "$(DMG)"
	@echo "  $(DMG)"

# Offline packaging: build, verify the identity, wrap. No network, no notary,
# no ticket. `dmg` briefly depended on notarize-app, which quietly turned local
# packaging into an upload requiring credentials — a target named `dmg` should
# not submit anything to Apple.
dmg:
	$(MAKE) -C .. $(HELPER_TARGET)
	$(MAKE) app CODESIGN_ID="$(CODESIGN_ID)" UNIVERSAL="$(UNIVERSAL)"
	$(MAKE) check-identity CODESIGN_ID="$(CODESIGN_ID)" UNIVERSAL="$(UNIVERSAL)"
	$(MAKE) package-dmg CODESIGN_ID="$(CODESIGN_ID)"
	@echo "  NOT notarized — Gatekeeper will reject this on another Mac."

# Stage two: wrap the already-stapled app, then notarize and staple the image.
notarize: notarize-app
	$(MAKE) package-dmg CODESIGN_ID="$(CODESIGN_ID)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	$(MAKE) verify-release

# What a user's machine will actually conclude — which is not what the build
# tree says. This used to assess $(APP_DIR): never quarantined, already launched
# here, and not the copy that comes out of the image. That check passes for
# builds a clean Mac will bounce.
#
# So: mount the real DMG, pull the app out the way a user does, mark it
# quarantined, and ask Gatekeeper. `--type open` is the assessment for the
# image; `--type execute` is the one for the app.
# No prerequisite on purpose — this must be runnable against an artifact built
# earlier, or one someone hands you. It refuses rather than assessing nothing.
verify-release:
	@test -f "$(DMG)" || { echo "  no $(DMG) — run: make notarize CODESIGN_ID=..." >&2; exit 1; }
	xcrun stapler validate "$(DMG)"
	hdiutil verify "$(DMG)"
	codesign --verify --strict --verbose=2 "$(DMG)"
	@echo "  --- Gatekeeper on the disk image ---"
	spctl --assess --type open --context context:primary-signature --verbose=2 "$(DMG)"
	@echo "  --- Gatekeeper on the app as a user receives it ---"
	@set -e; \
	 mkdir -p .build; \
	 mp="$$(mktemp -d .build/verify-mount.XXXXXX)"; mounted=0; \
	 trap 'if [ "$$mounted" = 1 ]; then hdiutil detach "$$mp" -quiet 2>/dev/null || true; fi; rmdir "$$mp" 2>/dev/null || true' EXIT; \
	 hdiutil attach -nobrowse -readonly -mountpoint "$$mp" "$(DMG)" >/dev/null; \
	 mounted=1; \
	 test -L "$$mp/Applications" || { echo "  ERROR: no /Applications symlink in the image" >&2; exit 1; }; \
	 rm -rf .build/verify && mkdir -p .build/verify; \
	 /usr/bin/ditto "$$mp/$(APP).app" ".build/verify/$(APP).app"; \
	 xattr -w com.apple.quarantine "0083;00000000;Safari;" ".build/verify/$(APP).app"; \
	 xcrun stapler validate ".build/verify/$(APP).app"; \
	 spctl --assess --type execute --verbose=2 ".build/verify/$(APP).app"; \
	 codesign --verify --deep --strict --verbose=2 ".build/verify/$(APP).app"; \
	 for b in "$(APP)" dishwatch-helper; do \
	   archs="$$(lipo -archs ".build/verify/$(APP).app/Contents/MacOS/$$b")"; \
	   case "$$archs" in \
	     *arm64*x86_64*|*x86_64*arm64*) echo "  $$b: $$archs" ;; \
	     *) echo "  ERROR: $$b is not universal: $$archs" >&2; exit 1 ;; \
	   esac; \
	 done; \
	 rm -rf .build/verify

clean-app:
	rm -rf "$(APP_DIR)" .build/AppIcon.iconset .build/appicon-1024.png \
	       .build/verify .build/$(APP)-*.dmg .build/$(APP)-*.zip
