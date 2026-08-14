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

## The CLI

```
git tag v0.1.3 && git push --tags
make publish            # goreleaser: 4 platforms, checksums, tap PR
make publish-dry        # same, into dist/, no upload
```

Requires a clean tree at a tag — goreleaser refuses otherwise.

Two things to know. The macOS binaries are **not signed or notarized**. Homebrew
installs are unaffected, because Homebrew's own download does not set the
`com.apple.quarantine` attribute; a user who downloads the tarball from the
Releases page in a browser does get it, and Gatekeeper will refuse the binary.
And `brews:` is deprecated in goreleaser (→ `homebrew_casks`). It still works,
but the migration changes the install stanza and how quarantine is handled, so
it is a deliberate change rather than a rename.

## The app, direct

```
xcrun notarytool store-credentials dishwatch \
  --apple-id you@example.com --team-id BKY9R5336T --password <app-specific>

make helper-universal                          # from the repo root
cd app
make notarize CODESIGN_ID="Developer ID Application: … (BKY9R5336T)" UNIVERSAL=1
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

## Verified on 2026-08-14

A universal, sandboxed, Developer ID, hardened-runtime bundle launches, spawns
its helper, and the helper holds an ESTABLISHED connection to
`192.168.100.1:9200`. Both binaries carry a secure timestamp and
`flags=0x10000(runtime)`. `check-identity` refuses ad-hoc, refuses an Apple
Development cert, and refuses a missing timestamp. The full `make notarize` flow
runs to the notary and stops only on the absent credential.

## Still unverified

**Notarization itself.** No submission has been made — the keychain profile does
not exist yet. Everything above is the shape of a correct submission, not proof
Apple accepts it.

**Gatekeeper on a machine that has never seen this app.** `verify-release`
quarantines its copy, which is closer than assessing the build tree, but this
Mac still has policy caches and has launched these binaries.

**Local Network TCC under a real identity on a clean account.** Every
measurement is from this machine. The connecting process is the helper; the
prompt identity should be the app, since `Process` preserves responsibility and
`inherit` covers the sandbox rather than TCC — but the shipped path is a Go BSD
socket rather than `NWConnection`, which is the stack Apple is least consistent
about. Needs a second Mac or a fresh account, not another code pass.

**Intel.** The binaries are universal and `lipo` confirms both slices, but
nothing here has executed the x86_64 slice.
