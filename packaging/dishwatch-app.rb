# Homebrew cask for the notarized macOS app, and the source of truth for
# faeton/homebrew-tap:Casks/dishwatch-app.rb. Do not edit the tap's copy — run
# `make cask` (after the DMG is uploaded), which renders this file with the
# version and DMG sha256 read out of the published release's checksums.txt.
# The version and sha256 below are placeholders that rendering overwrites.
#
# Hand-written rather than goreleaser-generated: goreleaser can only wrap
# artifacts it built, and the DMG comes from app/Makefile with two notarization
# round-trips and an embedded helper. Updating this file is therefore a required
# release step, not something `make publish` does for you.
#
# The token is `dishwatch-app`, NOT `dishwatch`. A tap may legally hold both a
# formula and a cask under one token, but Homebrew resolves the collision by
# preferring the formula and printing a warning — so `brew install
# faeton/tap/dishwatch` would quietly install the CLI and never mention that an
# app exists. Two tokens, two unambiguous commands:
#
#   brew install faeton/tap/dishwatch            → the CLI (macOS + Linux)
#   brew install --cask faeton/tap/dishwatch-app → the app  (macOS only)
#
# Why the CLI stays a formula: casks quarantine everything they download, and
# the CLI binaries are unsigned, so a cask would hand Gatekeeper exactly what it
# blocks. (Casks themselves are no longer macOS-only — only the `app` artifact
# is — so that is not the reason.)
cask "dishwatch-app" do
  version "0.2.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_UPLOADED_DMG"

  url "https://github.com/faeton/dishwatch/releases/download/v#{version}/DishWatch-#{version}.dmg"
  name "DishWatch"
  desc "Menu-bar monitor for Starlink dish status, performance, and power"
  homepage "https://github.com/faeton/dishwatch"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Matches LSMinimumSystemVersion in app/Resources/Info.plist and the
  # .macOS(.v14) platform in app/Package.swift. Keep all three in step.
  #
  # A bare symbol already means "this version or newer" — MacOSRequirement.parse
  # defaults to the `>=` comparator. The `">= :sonoma"` string spelling is the
  # deprecated form and warns.
  depends_on macos: :sonoma

  app "DishWatch.app"

  # The embedded helper needs no stanza of its own: it lives inside
  # Contents/MacOS, is spawned and supervised by the app, is never registered
  # with launchd, and exits when its stdin closes. Moving the bundle moves it.
  uninstall quit: "com.faeton.dishwatch"

  # Deliberately NOT `auto_updates true` — the app has no self-update mechanism,
  # so claiming one would stop Homebrew from ever upgrading it.
  #
  # Sandboxed, so all state lives in the container. ~/.cache/sl belongs to the
  # CLI formula and must not be zapped here.
  zap trash: [
    "~/Library/Application Scripts/com.faeton.dishwatch",
    "~/Library/Containers/com.faeton.dishwatch",
  ]
end
