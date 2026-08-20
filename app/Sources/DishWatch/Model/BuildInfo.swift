import Foundation

/// What this bundle is: which version, and whether it is a release or a build
/// someone made on their own machine.
///
/// The second half is the reason this type exists. `CFBundleShortVersionString`
/// is `git describe` stripped down to dotted digits — App Store Connect rejects
/// anything else — so a local test bundle and the notarized cask release cut
/// from the same tag both report `0.2.7`. Every surface that showed a version
/// showed that string, which meant no surface could tell the two apart, and the
/// one time it matters is exactly when someone is trying to confirm they are
/// looking at the build they just made.
///
/// `make app` writes `DWBuildChannel` and `DWSourceVersion` into the plist to
/// close that gap; see app/Makefile, where the channel is derived from the
/// signing identity rather than passed in.
struct BuildInfo: Equatable, Sendable {

    /// How the bundle was signed, which is the same question as whether it
    /// could ever have left the machine it was built on: an ad-hoc signature
    /// cannot be notarized and Gatekeeper refuses it everywhere else.
    enum Channel: String, Sendable {
        /// Signed with a real Developer ID. What the DMG and the cask install.
        case release
        /// Ad-hoc signed — `make app` with no `CODESIGN_ID`.
        case dev
        /// No `DWBuildChannel` in the plist at all. Not the same as `.dev`:
        /// this is a bundle assembled by something other than `make app`, or by
        /// a Makefile older than this key, and claiming either channel for it
        /// would be a guess. Renders as nothing.
        case unknown
    }

    /// `CFBundleShortVersionString` — dotted digits, e.g. `0.2.7`.
    let shortVersion: String
    /// `CFBundleVersion` — the monotonic build number, e.g. `89`.
    let buildNumber: String
    let channel: Channel
    /// The full `git describe`, e.g. `v0.2.7-1-gcdd29ad-dirty`. Empty when the
    /// bundle predates the key.
    let sourceVersion: String

    static let main = BuildInfo(bundle: .main)

    init(bundle: Bundle) {
        let info = bundle.infoDictionary
        shortVersion = info?["CFBundleShortVersionString"] as? String ?? ""
        buildNumber = info?["CFBundleVersion"] as? String ?? ""
        // An unrecognized channel string degrades to `.unknown` rather than
        // trapping, for the same reason the wire enums do: a value this build
        // has never heard of is not grounds to take the app down with it.
        channel = (info?["DWBuildChannel"] as? String)
            .flatMap(Channel.init(rawValue:)) ?? .unknown
        sourceVersion = info?["DWSourceVersion"] as? String ?? ""
    }

    /// Memberwise, for tests and for the render harness.
    init(shortVersion: String, buildNumber: String, channel: Channel, sourceVersion: String) {
        self.shortVersion = shortVersion
        self.buildNumber = buildNumber
        self.channel = channel
        self.sourceVersion = sourceVersion
    }

    /// Whether the working tree had uncommitted changes when this was built.
    ///
    /// `git describe --dirty` appends the suffix; nothing else in the string
    /// can produce it, since a tag containing "-dirty" would have been stripped
    /// by the same describe call that made this.
    var isDirty: Bool { sourceVersion.hasSuffix("-dirty") }

    /// What the footer prints after the connection status: `v0.2.7` for a
    /// release, `dev v0.2.7✱` for anything built locally.
    ///
    /// The channel word leads because it is the only part that distinguishes
    /// the two — both bundles cut from tag v0.2.7 report `0.2.7`, so a version
    /// on its own is exactly the string that already failed at this job.
    ///
    /// The commit is *not* here, and that is a size decision rather than a
    /// preference. This line shares ~290 pt with an IP, a status phrase and the
    /// Pin button, and the longest status ("sample data — not a real dish") is
    /// one a dev build shows routinely — with `dev · v0.2.7-1-gcdd29ad✱` in
    /// this slot the render harness truncated it to `dev · v0.2.7…`, losing the
    /// hash that was the whole reason for spending the room. `detailLabel` in
    /// Settings carries the full describe string, where nothing competes for
    /// the width and it can be selected and pasted.
    ///
    /// The star is `-dirty`, replaced rather than spelled: six characters of
    /// the panel's tightest line is a lot for a word one glyph says.
    ///
    /// `nil` for a bundle with no channel key — an unlabelled build gets no
    /// label rather than a guessed one.
    var footerLabel: String? {
        switch channel {
        case .unknown:
            return nil
        case .release:
            return shortVersion.isEmpty ? nil : "v\(shortVersion)"
        case .dev:
            guard !shortVersion.isEmpty else { return "dev" }
            return "dev v\(shortVersion)\(isDirty ? "✱" : "")"
        }
    }

    /// The long form, for Settings, where there is room for the whole thing and
    /// no reason to abbreviate: `0.2.7 (89) · dev · v0.2.7-1-gcdd29ad-dirty`.
    var detailLabel: String {
        var parts: [String] = []
        if !shortVersion.isEmpty {
            parts.append(buildNumber.isEmpty ? shortVersion : "\(shortVersion) (\(buildNumber))")
        }
        if channel != .unknown { parts.append(channel.rawValue) }
        // Spelled out here, `-dirty` and all. Settings is where someone goes to
        // copy a version into a bug report, and a star does not paste.
        if !sourceVersion.isEmpty, sourceVersion != shortVersion { parts.append(sourceVersion) }
        return parts.isEmpty ? "dev" : parts.joined(separator: " · ")
    }
}
