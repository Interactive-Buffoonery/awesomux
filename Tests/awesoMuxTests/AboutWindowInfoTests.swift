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
                let noticePath = directory.appendingPathComponent("\(notice.resource).\(notice.ext)")
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

    /// The source-tree test above proves the file exists in the repo, but the
    /// bundle only ships what `build_and_run.sh`'s `required_license_files`
    /// copies. A credit added to the manifest without updating that list would
    /// resolve in the repo yet ship a release with no license file and an absent
    /// button — green CI, legal omission. Assert every credit path is in the
    /// copied set so the two lists can't drift silently.
    @Test("Every credit license/notice is in build_and_run.sh's copied set")
    func creditFilesAreBundled() throws {
        let scriptURL = repositoryRoot.appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        // Extract the quoted entries between `required_license_files=(` and `)`.
        guard let arrayStart = script.range(of: "required_license_files=("),
            let arrayEnd = script.range(of: ")", range: arrayStart.upperBound..<script.endIndex)
        else {
            Issue.record("Could not locate required_license_files=( … ) in build_and_run.sh")
            return
        }
        let body = script[arrayStart.upperBound..<arrayEnd.lowerBound]
        let copied = Set(
            body.split(whereSeparator: \.isNewline)
                .compactMap { line -> String? in
                    // Skip commented-out entries — a `# "Ghostty/LICENSE"` line
                    // is NOT copied, so counting it would be the false green this
                    // test exists to prevent.
                    guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else {
                        return nil
                    }
                    guard let open = line.firstIndex(of: "\""),
                        let close = line.lastIndex(of: "\""), open < close
                    else { return nil }
                    return String(line[line.index(after: open)..<close])
                })
        #expect(!copied.isEmpty, "Parsed no entries from required_license_files")

        for credit in AboutCredit.all {
            for path in creditRelativePaths(credit) {
                #expect(
                    copied.contains(path),
                    "\(credit.name): \(path) is not in build_and_run.sh required_license_files")
            }
        }
    }

    /// `Licenses/`-relative paths a credit points at, matching the entries in
    /// `required_license_files` (e.g. `Ghostty/LICENSE`, `swift-markdown/NOTICE.txt`).
    private func creditRelativePaths(_ credit: AboutCredit) -> [String] {
        let license = credit.ext.map { "\(credit.resource).\($0)" } ?? credit.resource
        var paths = ["\(credit.subdirectory)/\(license)"]
        if let notice = credit.notice {
            paths.append("\(credit.subdirectory)/\(notice.resource).\(notice.ext)")
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
