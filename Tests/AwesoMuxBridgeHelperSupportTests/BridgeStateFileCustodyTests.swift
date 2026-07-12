import AwesoMuxCore
import Darwin
import Foundation
import Testing
@testable import AwesoMuxBridgeHelperSupport

@Suite
struct BridgeStateFileCustodyTests {

    private static let validJSON = Data(
        #"{"proto":"awesomux-bridge-v1","gen":1,"socket":"/tmp/awesomux-bridge-abc.sock","token":"tok"}"#.utf8
    )

    private static func makeTempPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-state-\(UUID().uuidString).json")
            .path
    }

    /// Writes `data` to a fresh temp file and `chmod`s it to `mode`.
    private static func writeFile(_ data: Data, mode: mode_t) -> String {
        let path = makeTempPath()
        FileManager.default.createFile(atPath: path, contents: data)
        chmod(path, mode)
        return path
    }

    @Test
    func validOwnerOnlyFilePasses() {
        let path = Self.writeFile(Self.validJSON, mode: 0o600)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let result = BridgeStateFileCustody.read(path: path)
        #expect(result?.socket == "/tmp/awesomux-bridge-abc.sock")
    }

    @Test
    func symlinkIsRejected() {
        let target = Self.writeFile(Self.validJSON, mode: 0o600)
        defer { try? FileManager.default.removeItem(atPath: target) }

        let linkPath = Self.makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: linkPath) }
        #expect(symlink(target, linkPath) == 0)

        #expect(BridgeStateFileCustody.read(path: linkPath) == nil)
    }

    // Wrong-owner rejection can't be exercised directly without root (there's
    // no way to fchown a file to another uid as an unprivileged test
    // process). `read`'s uid check (`st.st_uid == effectiveUID`) is exercised
    // instead via the `effectiveUID` override parameter, which is the same
    // code path a real uid mismatch would hit — an honest proxy, not a
    // substitute for a real cross-user test.
    @Test
    func mismatchedEffectiveUIDIsRejected() {
        let path = Self.writeFile(Self.validJSON, mode: 0o600)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let wrongUID = geteuid() + 1
        #expect(BridgeStateFileCustody.read(path: path, effectiveUID: wrongUID) == nil)
    }

    @Test
    func groupReadableModeIsRejected() {
        let path = Self.writeFile(Self.validJSON, mode: 0o640)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func worldReadableModeIsRejected() {
        let path = Self.writeFile(Self.validJSON, mode: 0o644)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func ownerExecutableModeIsRejected() {
        // Exactly 0600, not merely "no group/world": an owner-exec bit is
        // just as anomalous for a credential file the app writes as a group
        // bit, and "exact" must mean exact or the check drifts.
        let path = Self.writeFile(Self.validJSON, mode: 0o700)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func ownerReadOnlyModeIsRejected() {
        let path = Self.writeFile(Self.validJSON, mode: 0o400)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func setuidModeIsRejected() {
        // 04600: rwx triads alone read as a clean 0600 — the mask must also
        // cover the setuid/setgid/sticky bits for "exactly 0600" to hold.
        let path = Self.writeFile(Self.validJSON, mode: 0o4600)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func directoryIsRejected() {
        let path = Self.makeTempPath()
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func oversizeFileIsRejected() {
        // One byte past the 4 KiB cap.
        let oversized = Data(repeating: 0x61, count: BridgeStateFile.maximumByteCount + 1)
        let path = Self.writeFile(oversized, mode: 0o600)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func exactlyAtCapSizeIsAccepted() throws {
        // Confirms the size ceiling sits at maximumByteCount inclusive, not
        // one under it: pad a real, decodable state file's token so the
        // encoded JSON lands exactly at the cap and expect it to still pass
        // custody + parse (paired with oversizeFileIsRejected one byte up).
        let base = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/s.sock", token: "")
        let baseSize = try JSONEncoder().encode(base).count
        let padding = String(repeating: "a", count: BridgeStateFile.maximumByteCount - baseSize)
        let state = BridgeStateFile(proto: "awesomux-bridge-v1", gen: 1, socket: "/tmp/s.sock", token: padding)
        let data = try JSONEncoder().encode(state)
        #expect(data.count == BridgeStateFile.maximumByteCount)

        let path = Self.writeFile(data, mode: 0o600)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == state)
    }

    @Test
    func fifoIsRejectedWithoutBlocking() {
        // Without O_NONBLOCK this test doesn't fail — it HANGS the suite:
        // open(O_RDONLY) on a FIFO with no writer blocks forever, before
        // the S_IFREG check ever runs.
        let path = Self.makeTempPath()
        #expect(mkfifo(path, 0o600) == 0)
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func emptyFileIsRejected() {
        let path = Self.writeFile(Data(), mode: 0o600)
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Zero bytes passes custody (size 0 <= cap) but fails JSON decode.
        #expect(BridgeStateFileCustody.read(path: path) == nil)
    }

    @Test
    func nonAbsolutePathIsRejected() {
        #expect(BridgeStateFileCustody.read(path: "relative/path.json") == nil)
    }

    @Test
    func missingFileIsRejected() {
        #expect(BridgeStateFileCustody.read(path: Self.makeTempPath()) == nil)
    }
}
