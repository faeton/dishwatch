# Releasing

Three artifacts, three independent paths, and they do not share credentials:

| Artifact | Path | Credential | Status |
|---|---|---|---|
| `dishwatch` / `sl` CLI | goreleaser → GitHub Releases + Homebrew tap | `gh auth token` | working |
| `DishWatch.app` direct | Developer ID → notarized DMG | notarytool profile | working, needs the profile |
| `DishWatch.app` on the Store | Apple Distribution → `productbuild` → Transporter | two certs we do not have | blocked, see below |

The roadmap's stated priority is **Store first**, but the Store path is the one
blocked on certificates. Direct distribution works today and is a reasonable way
to get the app in front of real dishes before review.

## Cutting a full release

Order matters, and the reason is easy to miss: **the app's version comes from
`git describe`**. A DMG built before the tag carries the previous version in its
filename, its `CFBundleShortVersionString` and its notarization — and you will
not notice until the release page shows `DishWatch-0.1.2.dmg` under `v0.1.3`.

```
# 1. tag first
git tag v0.1.3 && git push --tags

# 2. THEN build and notarize the app, so it picks up the new version
cd app && make notarize CODESIGN_ID="Developer ID Application: … (BKY9R5336T)" UNIVERSAL=1

# 3. cut the release — goreleaser attaches the DMG via extra_files
cd .. && make publish
```

`make publish-dry` does everything but upload. Requires a clean tree at a tag;
goreleaser refuses otherwise.

## The CLI half

goreleaser builds four platforms, writes checksums, and pushes the Homebrew tap
formula.

The macOS binaries are **not signed or notarized**. Homebrew installs are
unaffected — a formula's download does not set `com.apple.quarantine` — but a
user who downloads the tarball from the Releases page in a browser does get it,
and Gatekeeper will refuse the binary.

That unsigned-ness is also why the CLI stays a **formula** rather than moving to
`homebrew_casks`, which goreleaser now prefers. Casks quarantine everything they
extract (`Cask::Quarantine.cask!`, applied recursively), so a cask-packaged
unsigned CLI is precisely what Gatekeeper blocks. Note the reason: **not**
because casks are macOS-only — they have not been since Homebrew 4.5, and only
the `app` artifact is macOS-bound.

So `brews:` stays deprecated-but-used, and `goreleaser check` exits non-zero
because of it. The exit condition is signing and notarizing the CLI itself
(`notarize.macos`, which needs a `.p12` export and an App Store Connect API key
rather than the notarytool keychain profile). That should happen before
goreleaser v3 removes the key, not merely "eventually".

## The app cask

`packaging/dishwatch-app.rb` is copied into the tap at release time with the
version and the SHA of the uploaded DMG (now in `checksums.txt`). This is a
manual release step — goreleaser only maintains taps for artifacts it built.

The token is `dishwatch-app`, not `dishwatch`. A tap may hold a formula and a
cask under the same token, but Homebrew resolves the collision by preferring the
formula and printing only a warning, so `brew install faeton/tap/dishwatch`
would install the CLI and never reveal that an app exists.

```
brew install faeton/tap/dishwatch             # CLI  — macOS + Linux
brew install --cask faeton/tap/dishwatch-app  # app  — macOS
```

## The app, direct

```
cd app
make notarize CODESIGN_ID="Developer ID Application: … (BKY9R5336T)" UNIVERSAL=1
```

That builds the matching universal engine itself. It used to want a separate
`make helper-universal` from the repo root first, and the very first real run
failed on exactly that — the thin-helper guard fired because the previous
command in the session had rebuilt a host-only helper. A guard should catch
mistakes, not the normal path.

The notarytool credential already exists on this machine as the keychain profile
`porter-notarization`, which is the Makefile default. A "profile" here is only a
local nickname for an Apple ID + team ID + app-specific password held in the
login keychain — nothing Apple issues, and **not** a provisioning profile. It is
per-account, not per-project, so the one another project created works here
unchanged. On a fresh machine:

```
xcrun notarytool store-credentials <any-name> \
  --apple-id you@example.com --team-id BKY9R5336T --password <app-specific>
```

**One command, and it must carry the identity.** A two-step
`make dmg CODESIGN_ID=… ; make notarize` does not work and is worth
understanding, because it fails in a confusing place: make does not carry
command-line variables between invocations, so the second command re-enters
`dmg` with the default ad-hoc identity and is refused by a guard whose message
is about ad-hoc builds — nothing points at the lost variable.

`make notarize` rebuilds rather than trusting an artifact on disk, because the
signing identity is a variable that leaves no trace in any prerequisite's mtime.

### Two tickets, not one

`notarize` submits twice: once for the `.app` (as a ditto'd zip), then again for
the DMG built around the now-stapled app.

Stapling only the DMG is the usual shortcut and it is not enough. The ticket
attaches to the container the user double-clicks; once they drag the app to
/Applications, that copy carries quarantine but no ticket, so first launch needs
`syspolicyd` to fetch one over the network. For an app whose users' internet
*is* the dish — plausibly down at exactly that moment — that is a likely path
rather than an edge case.

### Universal

`UNIVERSAL=1` builds both architectures; the default is host-only so dev builds
stay fast. Release artifacts must set it. An arm64-only DMG does not degrade on
an Intel Mac, it hard-fails, and it fails as "the application is damaged" —
which reads like a signing fault and sends you debugging the wrong thing. It
needs `make helper-universal` on the Go side too: `go build` is host-native, and
a universal app around an arm64-only helper launches on Intel and then dies on
every spawn, which looks like a dish problem.

`UNIVERSAL=1` now refuses to assemble a bundle around a host-only helper, which
is not a hypothetical: the first universal DMG built here had a universal app and
an arm64 helper, because `make helper` had last written a host-only binary and
the two build trees are independent. `verify-release` prints both architectures.

### The secure timestamp

`make app` signs `--timestamp=none` when `CODESIGN_ID` is ad-hoc and
`--timestamp` otherwise, and `make dmg` refuses to package a bundle whose
signature carries no `Timestamp=` line.

This is worth the two guards. Notarization requires a secure timestamp and
rejects without one — but `codesign --verify --deep --strict` passes either way,
so nothing local catches it. The rejection arrives after the upload and the
wait, and reads as a signing problem rather than a one-flag problem. The flag
was hardcoded off because ad-hoc signatures cannot carry a timestamp and the TSA
round-trip slows every dev build; it just has to flip for a real identity.

### Stapling

`notarytool` only registers the ticket with Apple. Without `stapler staple`, the
DMG passes Gatekeeper solely on a machine that can reach Apple to ask — a user
opening it offline or behind a captive portal gets the damaged-app dialog. For
an app whose entire audience is people whose internet is a satellite dish that
is sometimes down, this is a likely case rather than an edge one.

### Verification assesses the artifact, not the build tree

`make verify-release` mounts the finished DMG, copies the app out the way a user
does, **marks the copy quarantined**, and only then asks Gatekeeper.

The earlier version of this target assessed `.build/DishWatch.app` — never
quarantined, already launched on this machine, and not the copy that comes out
of the image. That check passes for builds a clean Mac will bounce, which is the
worst kind of green. It now runs `spctl --assess --type open` against the image
and `--type execute` against the extracted app, plus `hdiutil verify` and a
`lipo -archs` readout of both binaries.

It still is not a clean-machine test. Nothing local can be: this Mac has policy
caches and has launched these binaries. Before a first public release, open the
DMG on a Mac that has never seen the app.

### `make app SANDBOX=0` was broken

The unsandboxed control build signed the helper with
`com.apple.security.inherit` — "adopt my parent's sandbox" — while giving it an
unsandboxed parent. libsecinit aborts the child in its initializer:
`EXC_BREAKPOINT` before `main()`, no output, nothing the app can catch. The app
came up fine and the helper died on every spawn, at 5 crash reports per 30
seconds of retries, which presents as a dish problem rather than a packaging
one. The helper now gets those entitlements only when `SANDBOX=1`.

## The app, Mac App Store

Blocked on credentials, not code. This machine has **Developer ID Application**,
which signs for distribution *outside* the Store and cannot sign for it. The
Store needs:

- **Apple Distribution** — signs the app
- **3rd Party Mac Developer Installer** — signs the `.pkg`
- a **provisioning profile** for `com.faeton.dishwatch`
- an **App Store Connect** app record

It also needs a **third entitlements file**. `DishWatch.entitlements` is correct
for direct distribution and wrong for the Store, which additionally requires
`com.apple.application-identifier` (`BKY9R5336T.com.faeton.dishwatch`) and
`com.apple.developer.team-identifier`. Both depend on the team ID, which is why
the file cannot be written speculatively. The comment at the top of
`DishWatch.entitlements` says the same thing; do not edit that file to serve
both.

Packaging is `productbuild --component … --sign "3rd Party Mac Developer
Installer: …"`, then upload. No notarization — the Store notarizes on its side.

Everything else the submission needs is in roadmap.md: the scaffolding to cut,
the Guideline 5.2 trademark exposure, the `PrivacyInfo.xcprivacy` reasons, and
the non-code work (screenshots, privacy policy URL, export compliance).

## Shipped: v0.2.1, 2026-08-15

`DishWatch-0.2.1.dmg` — a patch for the energy figure; notes in
[release-notes-v0.2.1.md](release-notes-v0.2.1.md). Both notary submissions
Accepted, DMG sha256 verified against the download rather than only against
`checksums.txt`, formula and cask both at 0.2.1, and both upgraded and run here.

Found by looking at the app rather than at a test: the Power cell read
`90.3 Wh since boot` for a dish that had drawn roughly 900, and the CLI's Energy
line published `avg 4724.1 W`. Neither is reachable from a fixture — both needed
a real `state.json` whose two counters had drifted apart on a real machine.

## Shipped: v0.2.0, 2026-08-15

`DishWatch-0.2.0.dmg` — universal, notarized and stapled, published at
[releases/tag/v0.2.0](https://github.com/faeton/dishwatch/releases/tag/v0.2.0)
with the four CLI tarballs, `checksums.txt`, a goreleaser-updated formula and a
hand-updated cask. Notes in [release-notes-v0.2.0.md](release-notes-v0.2.0.md).

Both notary submissions Accepted first try. The published DMG, the artifact
Apple notarized, and the file `curl` fetches from the release URL are the same
object:

```
6e602e776a3f236fe97179e2171a1a020fe5e12174403ccb9f51d789d71eeb06
```

That was checked against the download this time, not just against
`checksums.txt` — the cask's `sha256` is a claim about what a user receives, so
it is worth verifying from the user's side of the wire before pushing it.

### The cask upgrade path finally ran

`brew upgrade --cask` is the item the v0.1.3 section listed as never-exercised,
because there was no earlier version to upgrade from. There is now, and it
works: 0.1.3 backed up, `/Applications/DishWatch.app` replaced, old version
purged. Then the real thing rather than a simulation of it — `stapler validate`,
`spctl accepted / Notarized Developer ID`, launched from `/Applications`, helper
spawned, and an ESTABLISHED connection to `192.168.100.1:9200`.

The formula upgrade ran too, and `dishwatch json --window 900` returns 900
samples from the *shipped* binary. Test the CLI by absolute path: `~/.local/bin/sl`
is a stale repo build that shadows Homebrew in `PATH`.

### Ordering held up

The tag-before-notarize rule this document opens with did its job silently:
`DishWatch-0.2.0.dmg` carries 0.2.0 in its filename, its
`CFBundleShortVersionString` and its notarization, because the tag was pushed
first. Nothing had to be rebuilt.

### The tap goes red between the formula push and the cask push

Expect one failing tap CI run per release, and do not go looking for a bug in
it. `make publish` creates the GitHub release and pushes the formula in the same
goreleaser step; the cask is a separate manual commit that cannot be made any
earlier, because its `sha256` is the hash of a DMG that only exists once
notarization has finished. So there is always a window where the tap's cask says
the old version while `livecheck` can already see the new release, and
`brew audit` correctly refuses it:

```
Version '0.1.3' differs from '0.2.0' retrieved by livecheck.
```

Here the window was 2m16s and the next run was green. It cannot be closed by
reordering — pushing the cask first would fail the other way, on a `url` that
404s until the release exists. The fix, if it is ever worth one, is to teach the
audit job to tolerate a cask that trails the newest release by one version, or
to have `make publish` do the cask commit itself.

One thing to know for next time: the Homebrew-managed tap checkout at
`/opt/homebrew/Library/Taps/faeton/homebrew-tap` had unrelated uncommitted edits
(another project's cask, plus a formula description fix that goreleaser has since
made redundant). The cask update was therefore made in a throwaway clone rather
than in that working copy, which is the right habit regardless — that directory
belongs to Homebrew, not to this release.

## Shipped: v0.1.3, 2026-08-14

`DishWatch-0.1.3.dmg` — 11 MB, universal, notarized and stapled, published at
[releases/tag/v0.1.3](https://github.com/faeton/dishwatch/releases/tag/v0.1.3)
with the CLI tarballs, `checksums.txt`, an updated formula and a new cask.

Four notary submissions across the day, every one Accepted first try: a 0.1.2
rehearsal (`e4e0b75e`, then `e4b19cdf` once universal), then the real pair for
0.1.3 — the `.app`, and `444f2b24` for the DMG built around it.

The published DMG's SHA-256 matches the file that was notarized, byte for byte:

```
825ccc56dc1137ad401beaf3eb875d438d5a7852557c8c6c138427dd61ba1612
```

That equality is the whole point of putting the DMG in `checksums.txt` — the
cask's `sha256` is only meaningful if the notarized artifact and the downloaded
one are the same object.

`verify-release` on a quarantined copy extracted from the mounted image:

```
DishWatch-0.1.3.dmg:  accepted   source=Notarized Developer ID
verify/DishWatch.app: accepted   source=Notarized Developer ID
  DishWatch:        x86_64 arm64
  dishwatch-helper: x86_64 arm64
```

Then the real install path, not a simulation of it: `brew install --cask
faeton/tap/dishwatch-app` → `/Applications` → `stapler validate` → `spctl
accepted` → launched → the helper spawned and held an ESTABLISHED connection to
192.168.100.1:9200. Gatekeeper accepting a bundle and the bundle working are
different claims; both are measured.

### The version guard paid for itself immediately

`make package-dmg` wrote `DishWatch-0.1.3.dmg` directly beside a leftover
`DishWatch-0.1.2.dmg`. Under the previous `DishWatch-*.dmg` glob the release
could have carried the older app, or both. Version-exact globbing caught the
exact case it was written for, hours after being written.

## Verified on 2026-08-14

A universal, sandboxed, Developer ID, hardened-runtime bundle launches, spawns
its helper, and the helper holds an ESTABLISHED connection to
`192.168.100.1:9200`. Both binaries carry a secure timestamp and
`flags=0x10000(runtime)`. `check-identity` refuses ad-hoc, refuses an Apple
Development cert, and refuses a missing timestamp. The full `make notarize` flow
runs to the notary and stops only on the absent credential.

## Still unverified

**First launch with the network down.** The stapled ticket should make an
offline first launch work; that has not been tested with the network actually
unplugged, and it is the case this project's users are most likely to hit.

**Local Network TCC on a clean account.** The real-identity half is now done:
the notarized DMG installed to /Applications and connected to the dish with no
Local Network prompt at all. But this account has launched ad-hoc builds of the
app many times, so a silent pre-existing grant cannot be ruled out from here. A
never-before-seen user account is the one experiment that settles it. See
roadmap.md Phase 2 for the full evidence and its limits.

**Intel.** The binaries are universal and `lipo` confirms both slices, but
nothing here has executed the x86_64 slice.

**Cask upgrade.** ~~Install and Gatekeeper assessment are covered; `upgrade` has
never run, because there is no earlier cask version to upgrade from.~~ Settled by
the v0.2.0 release above. `--zap` uninstall is still unverified: its paths are a
best guess until `brew generate-zap` is run against a real launched install.

## Settled by the tap CI, 2026-08-14

**Gatekeeper on a machine that has never seen the app.** A `macos-15` runner —
fresh, no policy cache, no prior launch — installed the cask, which downloads
and quarantines the DMG, and `spctl` returned `accepted`. That is the
clean-machine check this document said could not be done locally.

**The formula on Linux.** Its `on_linux` block had shipped since v0.1.0 without
ever being installed anywhere. It installs: `dishwatch` and `sl` both report
0.1.3 on ubuntu-latest and `sl --help` runs.

Getting there took four attempts, all of them the CI's fault rather than the
tap's, and worth recording so nobody repeats them: `brew style` failed on a
100-character formula description (over Homebrew's 80 limit, shipped that way
since v0.1.0); `brew audit --online` exhausted the runner's 60 unauthenticated
GitHub requests; and the Linux job fought `setup-homebrew` over the tap
directory twice — nesting the repo inside itself, then leaving a real directory
where the action's cleanup expected its own symlink. The action already
symlinks the checkout in as the tap, so the correct amount of staging is none.

## Review round, 2026-08-14 (post-v0.1.3)

### The tap CI could go green on a broken tap

Three false-green paths, all now closed.

`brew audit --formula` was wrapped in `|| true`, so *every* formula audit
failure became a pass. It was written that way to tolerate one unavoidable
goreleaser artefact — the generated formula carries `version` alongside per-arch
URLs, which `--strict` calls redundant — but discarding the whole audit to
silence one false positive also discarded a 404 URL and a stale sha256. Split in
two: the lint stays advisory and now surfaces as a GitHub warning annotation
instead of vanishing, and a new fatal step checks every `url`/`sha256` pair in
every formula and cask against what is actually published. All seven assets in
the tap verify today — the four DishWatch tarballs, the DMG, and the two from
the tap's other projects; tampering with a hash and pointing a URL at a missing
file both fail it. Each of these loops also counts what it processed and fails
on zero, because a clean `brew audit` prints nothing at all and an empty glob
would otherwise be indistinguishable from a pass.

The universality check `echo`ed `lipo -archs` and moved on. A DMG containing
only the runner's own slice passes install, `stapler` and `spctl` identically to
a universal one, so CI would have gone green on a build that cannot start on
half the Macs it is offered. It asserts now.

And the formula was only ever installed on Linux, so the Darwin tarballs — a
different URL and a different sha from the Linux ones — reached users
unexercised. The macOS job installs and runs the CLI too.

### The bash lock, broken once in each direction

Covered in full in `docs/optimizations.md`; the release-relevant part is that
neither break was catchable by anything this project ran. `go test` never loads
the bash script, and each break was invisible from the platform its author was
sitting at. `scripts/check-sl-lock.sh` now runs on both platforms in CI and
asserts the half that a "degrade quietly" bug destroys: that the lock is
*refused* when genuinely held.

### The landing page was deployed as a fragment

`site/index.html` began at `<title>` — no doctype, no `<html>`, no `<head>`, no
`<meta name="viewport">`. That shape is fine where something wraps it, and wrong
for GitHub Pages, which serves the file verbatim. Two consequences: the live
site rendered in quirks mode, and every phone laid it out at the ~980px default
and shrank it to fit. Now a complete document.

The desktop rendering is unaffected — the before and after screenshots are
byte-identical, because the stylesheet already sets `box-sizing` on everything,
which is the main thing quirks mode would otherwise have changed. There is no
horizontal overflow at the narrowest width Chrome will render (500px). The
mobile improvement itself is asserted from the specified behaviour of the
viewport meta, not measured on a device.

### `check-version` accepted a dirty tree

`git describe --exact-match` is perfectly happy with uncommitted edits, so a
build from modified sources would notarize and ship with every version string
reading like the tag. It now requires a clean tree, untracked files included —
SwiftPM compiles everything under `Sources/` whether git knows about it or not.
The tag is the only provenance a downloader has.
