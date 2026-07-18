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

    /// Repo root derived from this test file's location:
    /// `<root>/Tests/awesoMuxTests/AboutWindowInfoTests.swift`.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // awesoMuxTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // root
    }
}
