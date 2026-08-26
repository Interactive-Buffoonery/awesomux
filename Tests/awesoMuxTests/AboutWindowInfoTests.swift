import AwesoMuxTestSupport
import Foundation
import Testing

@testable import awesoMux

@Suite("About window metadata + credits")
struct AboutWindowInfoTests {
    // MARK: - Version formatting

    @Test("Version and build combine as `version (build)`")
    func versionWithBuild() {
        #expect(AboutInfo.formatVersion(short: "0.3.0", build: "128") == "0.3.0 (128)")
    }

    @Test("Missing build shows the bare version")
    func versionOnly() {
        #expect(AboutInfo.formatVersion(short: "0.3.0", build: nil) == "0.3.0")
    }

    @Test("Missing version falls back to the bare build")
    func buildOnly() {
        #expect(AboutInfo.formatVersion(short: nil, build: "128") == "128")
    }

    @Test("Empty strings are treated as absent, not rendered")
    func emptyStringsTreatedAsMissing() {
        #expect(AboutInfo.formatVersion(short: "", build: "") == "Development")
        #expect(AboutInfo.formatVersion(short: "0.3.0", build: "") == "0.3.0")
    }

    @Test("Non-bundle run with no version keys reads as Development")
    func developmentFallback() {
        #expect(AboutInfo.formatVersion(short: nil, build: nil) == "Development")
    }

    // MARK: - Info dictionary injection

    @Test("Injected info values populate version and revision")
    func infoValueInjection() {
        let info = AboutInfo(infoValue: { key in
            [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "42",
                "AwesoMuxSourceRevision": "abc1234",
            ][key]
        })
        #expect(info.version == "1.2.3 (42)")
        #expect(info.sourceRevision == "abc1234")
    }

    @Test("Empty or absent revision resolves to nil so the row hides")
    func revisionAbsentIsNil() {
        let empty = AboutInfo(infoValue: { $0 == "AwesoMuxSourceRevision" ? "  " : nil })
        #expect(empty.sourceRevision == nil)

        let absent = AboutInfo(infoValue: { _ in nil })
        #expect(absent.sourceRevision == nil)
    }

    // MARK: - Credits license resolution

    /// The real failure mode: a dependency bump renames a license file, the
    /// manifest goes stale, and the "View license" button silently no-ops.
    /// Resolve every manifest entry against the source `Resources/Licenses`
    /// tree (the same files `script/build_and_run.sh` copies into the bundle).
    @Test("Every credit's license (and notice) file exists in Resources/Licenses")
    func creditLicenseFilesResolve() {
        let licensesRoot =
            repositoryRoot
            .appendingPathComponent("Resources/Licenses", isDirectory: true)

        for credit in AboutCredit.all {
            let directory = licensesRoot.appendingPathComponent(credit.subdirectory, isDirectory: true)
            let fileName = credit.ext.map { "\(credit.resource).\($0)" } ?? credit.resource
            let licensePath = directory.appendingPathComponent(fileName)
            #expect(
                FileManager.default.fileExists(atPath: licensePath.path),
                "Missing license file for \(credit.name): \(licensePath.path)")

            if let notice = credit.notice {
                let noticeName = notice.ext.map { "\(notice.resource).\($0)" } ?? notice.resource
                let noticePath = directory.appendingPathComponent(noticeName)
                #expect(
                    FileManager.default.fileExists(atPath: noticePath.path),
                    "Missing notice file for \(credit.name): \(noticePath.path)")
            }
        }
    }

    @Test("Credit names are unique (Identifiable id stability)")
    func creditNamesUnique() {
        let names = AboutCredit.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("Sparkle is credited with its bundled MIT license")
    func sparkleCredit() {
        let sparkle = AboutCredit.all.first { $0.name == "Sparkle" }

        #expect(sparkle?.attribution == "Software updates — MIT")
        #expect(sparkle?.resource == "LICENSE")
        #expect(sparkle?.ext == nil)
        #expect(sparkle?.subdirectory == "Sparkle")
    }

    @Test("Every audited GhosttyKit component has an About credit")
    func ghosttyKitComponentsAreCredited() {
        let credited = Set(AboutCredit.all.map(\.name))
        let expected: Set<String> = [
            "FreeType", "libpng", "zlib", "Oniguruma", "GNU gettext libintl",
            "Dear Bindings", "Dear ImGui", "sentry-native", "MPack", "stb_sprintf",
            "Google Breakpad", "simdutf", "Highway", "glslang", "SPIRV-Cross", "Wuffs",
        ]

        #expect(expected.isSubset(of: credited))
    }

    /// The source-tree test above proves the file exists in the repo, but the
    /// bundle only ships what `build_and_run.sh`'s `required_license_files`
    /// copies. A credit added to the manifest without updating that list would
    /// resolve in the repo yet ship a release with no license file and an absent
    /// button — green CI, legal omission. Assert every credit path is in the
    /// copied set so the two lists can't drift silently.
    @Test("Every credit license/notice is in build_and_run.sh's copied set")
    func creditFilesAreBundled() throws {
        let copied = try bundledLicensePaths()

        for credit in AboutCredit.all {
            for path in creditRelativePaths(credit) {
                #expect(
                    copied.contains(path),
                    "\(credit.name): \(path) is not in build_and_run.sh required_license_files")
            }
        }
    }

    /// The inverse of the test above, and the direction that was actually
    /// missing: every prior check walks outward from `AboutCredit.all`, so a
    /// component we *ship* a license for but never list in the About window is
    /// invisible to all of them. Selenized shipped that way — bundled, copied by
    /// `build_and_run.sh`, recorded in `Resources/Licenses/README.md`, and absent
    /// from the credits — because nothing asserted this direction. The bundle is
    /// what users receive, so it, not the manifest, is the authority on what
    /// needs attribution.
    @Test("Every bundled license directory has an About credit")
    func bundledLicensesAreCredited() throws {
        let creditedSubdirectories = Set(AboutCredit.all.map(\.subdirectory))
        let bundledSubdirectories = Set(
            try bundledLicensePaths().compactMap { $0.split(separator: "/").first.map(String.init) })

        #expect(!bundledSubdirectories.isEmpty, "Parsed no subdirectories from required_license_files")

        let uncredited = bundledSubdirectories.subtracting(creditedSubdirectories).sorted()
        #expect(
            uncredited.isEmpty,
            "Shipped with no About credit row: \(uncredited.joined(separator: ", "))")
    }

    @Test("Every GhosttyKit audit license is copied into the app bundle")
    func ghosttyKitAuditLicensesAreBundled() throws {
        let manifest = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "script/ghostty-third-party-components.tsv"),
            encoding: .utf8)
        let auditedPaths = Set(
            manifest.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
                guard !line.hasPrefix("#") else { return [] }
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 4 else {
                    Issue.record("Malformed GhosttyKit audit row: \(line)")
                    return []
                }
                return fields[3].split(separator: "|").map(String.init)
            })
        let copied = try bundledLicensePaths()
        let missingPaths = auditedPaths.subtracting(copied).sorted().joined(separator: ", ")

        #expect(!auditedPaths.isEmpty, "GhosttyKit audit manifest has no license paths")
        #expect(
            auditedPaths.isSubset(of: copied),
            "GhosttyKit audit licenses missing from required_license_files: \(missingPaths)")
    }

    /// `Resources/Licenses/README.md` records which upstream revision each
    /// bundled license text was copied from. Neither submodule row had been
    /// touched since the initial open-source seed — seven Ghostty bumps — before
    /// this test existed. The license *texts* stayed correct the whole time, so
    /// nothing user-visible broke; the provenance record just quietly stopped
    /// being true, which is why only an assertion catches it.
    ///
    /// `bundledLicenseMatchesSubmodule` closes the obvious hole in this: on its
    /// own, the check below only proves the README quotes the right SHA, so the
    /// cheapest way to silence a bot-bump failure would be to paste the new SHA
    /// without re-copying `LICENSE`, leaving the row honest about a revision
    /// whose text it no longer reflects.
    ///
    /// The font and theme rows (Hack Nerd Font Mono, Geist Sans, Selenized) name
    /// upstream release tags with no in-repo pin, so there is nothing to compare
    /// them against here.
    @Test("Licenses README records the pinned revision of every checkable row")
    func licenseReadmeMatchesPinnedRevisions() throws {
        let readme = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Resources/Licenses/README.md"),
            encoding: .utf8)

        for (row, path) in [("Ghostty", "vendor/ghostty"), ("zmx / amx", "vendor/zmx")] {
            guard let pinned = try gitlinkSHA(for: path) else {
                Issue.record("Could not read the committed gitlink for \(path)")
                continue
            }
            expectReadme(readme, row: row, records: pinned, source: path)
        }

        // The SwiftPM rows drift the same way, just triggered by a
        // `Package.resolved` bump instead of a submodule bump — and the pin is
        // already in the repo, so checking them costs nothing extra.
        let resolved = try swiftPMPinnedRevisions()
        for (row, identity) in [
            ("swift-toml", "swift-toml"),
            ("swift-markdown", "swift-markdown"),
            ("swift-cmark", "swift-cmark"),
        ] {
            guard let pinned = resolved[identity] else {
                Issue.record("Package.resolved has no pin for \(identity)")
                continue
            }
            expectReadme(readme, row: row, records: pinned, source: "Package.resolved")
        }
    }

    /// The bundled license text must be the text at the pinned revision.
    ///
    /// No network: the submodule is already checked out, so the upstream blob is
    /// readable straight out of its object database. That makes provenance a real
    /// assertion rather than bookkeeping — pasting a fresh SHA into the README
    /// without re-copying the file now fails here even though the row itself
    /// looks correct.
    @Test("Each bundled submodule license is the text at its pinned revision")
    func bundledLicenseMatchesSubmodule() throws {
        for (path, bundled) in [
            ("vendor/ghostty", "Ghostty/LICENSE"),
            ("vendor/zmx", "zmx/LICENSE"),
        ] {
            guard let pinned = try gitlinkSHA(for: path) else {
                Issue.record("Could not read the committed gitlink for \(path)")
                continue
            }
            guard let upstream = try submoduleBlob(in: path, revision: pinned, file: "LICENSE") else {
                Issue.record(
                    "Could not read LICENSE at \(pinned) from \(path) — is the submodule initialized?")
                continue
            }
            let shipped = try String(
                contentsOf:
                    repositoryRoot
                    .appendingPathComponent("Resources/Licenses")
                    .appendingPathComponent(bundled),
                encoding: .utf8)
            #expect(
                shipped == upstream,
                "Resources/Licenses/\(bundled) differs from \(path) LICENSE at the pinned \(pinned)")
        }
    }

    /// A file's contents at `revision` inside an initialized submodule.
    private func submoduleBlob(in path: String, revision: String, file: String) throws -> String? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = [
            "-C", repositoryRoot.appendingPathComponent(path).path,
            "show", "\(revision):\(file)",
        ]
        let (stdout, _) = try captureOutput(of: git, deadline: .seconds(10))
        guard git.terminationStatus == 0 else { return nil }
        return stdout
    }

    /// Compares the SHA cell of a Licenses README table row.
    ///
    /// Splits the row on `|` and trims rather than matching a padded substring:
    /// an exact-whitespace `contains` turns any cosmetic table realignment into a
    /// failure that reads as pin drift, pointing the reader at the wrong cause.
    private func expectReadme(
        _ readme: String, row: String, records pinned: String, source: String
    ) {
        let recorded =
            readme
            .split(whereSeparator: \.isNewline)
            .first { line in
                line.split(separator: "|").first.map {
                    $0.trimmingCharacters(in: .whitespaces) == row
                } ?? false
            }
            .flatMap { line -> String? in
                let cells = line.split(separator: "|").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard cells.count > 1 else { return nil }
                return cells[1].trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            }

        guard let recorded else {
            Issue.record("Licenses README has no row named \"\(row)\"")
            return
        }
        #expect(
            recorded == pinned,
            "Licenses README row \"\(row)\" records \(recorded) but \(source) is at \(pinned)")
    }

    /// Pinned revisions from `Package.resolved`, keyed by package identity.
    private func swiftPMPinnedRevisions() throws -> [String: String] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("Package.resolved"))
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = root?["pins"] as? [[String: Any]] ?? []
        return pins.reduce(into: [:]) { result, pin in
            guard let identity = pin["identity"] as? String,
                let state = pin["state"] as? [String: Any],
                let revision = state["revision"] as? String
            else { return }
            result[identity] = revision
        }
    }

    /// The SHA the revision under test pins a submodule at, via `git rev-parse`.
    /// Reads the committed gitlink rather than the submodule's checked-out HEAD,
    /// so a locally dirty or half-updated submodule cannot turn this green.
    ///
    /// Capture goes through `captureOutput(of:deadline:)` rather than a
    /// hand-rolled `Pipe`: a pipe holds ~64KB, and any order that reads one pipe
    /// while leaving another undrained can deadlock on a child that writes past
    /// that. `ProcessWaitBoundedGuardTests` does not catch this shape — it only
    /// rejects a bare `waitUntilExit()` — so the helper is the guard.
    private func gitlinkSHA(for path: String) throws -> String? {
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["-C", repositoryRoot.path, "rev-parse", "HEAD:\(path)"]
        let (stdout, _) = try captureOutput(of: git, deadline: .seconds(10))
        guard git.terminationStatus == 0 else { return nil }
        let sha = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    // MARK: - Cmd-W auxiliary-window routing

    @Test("Settings and About windows are auxiliary close targets")
    func auxiliaryCloseTargets() {
        #expect(AwesoMuxWindowRole.isAuxiliaryCloseTarget(.about))
        #expect(AwesoMuxWindowRole.isAuxiliaryCloseTarget(.settings))
    }

    @Test("Primary and unclassified windows are not auxiliary close targets")
    func nonAuxiliaryCloseTargets() {
        // Fail-closed: the primary window (and a window whose role isn't yet
        // assigned) must keep normal Cmd-W pane routing, not be force-closed.
        #expect(!AwesoMuxWindowRole.isAuxiliaryCloseTarget(.primaryContent))
        #expect(!AwesoMuxWindowRole.isAuxiliaryCloseTarget(nil))
    }

    /// The `Licenses/`-relative paths `script/build_and_run.sh` copies into the
    /// app bundle, parsed from its `required_license_files` array — the single
    /// source of truth for what a release actually ships.
    ///
    /// Every non-blank, non-comment line inside the array must yield a path or
    /// this records an issue. Returning a silent *subset* is the dangerous
    /// failure: `bundledLicensesAreCredited` compares against what it parsed, so
    /// an entry this dropped is an entry that test cannot notice is uncredited —
    /// and a non-empty check does not help, because a subset is still non-empty.
    /// A single-quoted entry, identical in bash, was enough to reproduce it.
    private func bundledLicensePaths() throws -> Set<String> {
        let scriptURL = repositoryRoot.appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        // Anchor on the declaration at the start of a line, so a future doc
        // comment or example mentioning the array name cannot capture the scan
        // ahead of the real one.
        let allLines = script.split(whereSeparator: \.isNewline)
        guard
            let declarationIndex = allLines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("required_license_files=(")
            })
        else {
            Issue.record("Could not locate required_license_files=( in build_and_run.sh")
            return []
        }

        let body = allLines[allLines.index(after: declarationIndex)...]
        // Strip any trailing comment before testing for the terminator: `)  # end
        // of array` is a natural edit, and an exact `== ")"` match would run the
        // scan off the end of the array into unrelated shell.
        let entryLines = body.prefix { !uncommented($0).hasPrefix(")") }
        #expect(entryLines.count < body.count, "Never found the closing ) of required_license_files")

        // A `required_license_files+=(...)` append elsewhere in the script would
        // ship files this scan never sees, leaving both direction tests green
        // while the appended component goes uncredited. Cheaper to forbid the
        // shape than to parse every place bash could grow the array.
        #expect(
            !script.contains("required_license_files+="),
            "required_license_files is appended to elsewhere; this parser only reads the literal array")

        var paths: Set<String> = []
        for line in entryLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // A `# "Ghostty/LICENSE"` line is NOT copied, so counting it would be
            // the false green this test exists to prevent.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let path = quotedValue(in: trimmed) else {
                Issue.record("Unparsed required_license_files entry, so it is unchecked: \(trimmed)")
                continue
            }
            paths.insert(path)
        }
        #expect(!paths.isEmpty, "Parsed no entries from required_license_files")
        return paths
    }

    /// `line` with any trailing `#` comment removed, trimmed.
    private func uncommented(_ line: some StringProtocol) -> String {
        String(line.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
    }

    /// The contents of the first single- or double-quoted run in `line`. Both
    /// quote styles are accepted because bash treats them identically here, so a
    /// reformat that swaps them must not change what this test sees.
    private func quotedValue(in line: String) -> String? {
        for quote in ["\"", "'"] as [Character] {
            guard let open = line.firstIndex(of: quote),
                let close = line.lastIndex(of: quote),
                open < close
            else { continue }
            return String(line[line.index(after: open)..<close])
        }
        return nil
    }

    /// `Licenses/`-relative paths a credit points at, matching the entries in
    /// `required_license_files` (e.g. `Ghostty/LICENSE`, `swift-markdown/NOTICE.txt`).
    private func creditRelativePaths(_ credit: AboutCredit) -> [String] {
        let license = credit.ext.map { "\(credit.resource).\($0)" } ?? credit.resource
        var paths = ["\(credit.subdirectory)/\(license)"]
        if let notice = credit.notice {
            let noticeName = notice.ext.map { "\(notice.resource).\($0)" } ?? notice.resource
            paths.append("\(credit.subdirectory)/\(noticeName)")
        }
        return paths
    }

    /// Repo root derived from this test file's location:
    /// `<root>/Tests/awesoMuxTests/AboutWindowInfoTests.swift`.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // awesoMuxTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // root
    }
}
