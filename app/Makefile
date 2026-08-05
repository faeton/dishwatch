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
CONFIG     := debug
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

# Built by the repo's own Makefile; not rebuilt here, so `make app` stays a
# packaging step rather than a cross-language build.
HELPER_SRC ?= ../bin/dishwatch

SANDBOX    ?= 1
ifeq ($(SANDBOX),1)
ENTITLEMENTS := Resources/$(APP).entitlements
else
ENTITLEMENTS := Resources/$(APP)-nosandbox.entitlements
endif

# Ad-hoc by default. That is enough to make the sandbox and TCC real on this
# machine, which is what the spike needs; it is not enough to distribute.
CODESIGN_ID ?= -

.PHONY: app run icon clean-app test

# Always reassembles rather than treating $(APP_DIR) as a file target. A
# directory target compares mtimes against sources, which is wrong here in a way
# that costs real debugging time: SANDBOX and CODESIGN_ID change the *output*
# without touching any prerequisite, so `make app SANDBOX=0` after `make app`
# would print "sandbox=0" and hand you back the sandboxed bundle. Assembling is
# a copy and a codesign — cheap enough that caching it buys nothing and can lie.
app:
	swift build -c $(CONFIG)
	rm -rf "$(APP_DIR)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	cp "$(BUILD_DIR)/$(APP)" "$(CONTENTS)/MacOS/$(APP)"
	# The engine. A sandboxed app cannot reach a CLI installed outside its
	# bundle, so this is not a convenience — it is the only path that works for
	# the Store build.
	@test -x "$(HELPER_SRC)" || { echo "  missing $(HELPER_SRC) — run: (cd .. && go build -o bin/dishwatch .)" >&2; exit 1; }
	cp "$(HELPER_SRC)" "$(CONTENTS)/MacOS/dishwatch-helper"
	cp Resources/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(SHORT_VER)" "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUM)" "$(CONTENTS)/Info.plist"
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)" "$(CONTENTS)/Info.plist"
	printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	# --force because the SwiftPM binary may already carry an ad-hoc signature
	# from the linker; without it codesign refuses rather than replacing.
	# Nested code first, inside-out, or the outer seal covers a stale hash.
	# The helper gets `inherit` rather than the app's own entitlements: Apple's
	# embedded-tool rule is that a child inherits the parent's sandbox, and
	# handing it an independent profile is what breaks that.
	codesign --force --sign "$(CODESIGN_ID)" \
	         --entitlements Resources/helper.entitlements \
	         --options runtime --timestamp=none \
	         "$(CONTENTS)/MacOS/dishwatch-helper"
	codesign --force --sign "$(CODESIGN_ID)" \
	         --entitlements "$(ENTITLEMENTS)" \
	         --options runtime \
	         --timestamp=none \
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

clean-app:
	rm -rf "$(APP_DIR)" .build/AppIcon.iconset .build/appicon-1024.png
