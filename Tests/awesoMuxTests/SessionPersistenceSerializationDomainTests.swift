import Foundation
import Testing

@Suite("SessionPersistence shared-state serialization", .serialized)
struct SessionPersistenceSerializationDomainTests {
    @Test("every temporary support-directory caller uses this serialized parent")
    func temporarySupportDirectoryCallersShareSerializationDomain() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let helperCall = "SessionPersistence." + "withTemporarySupportDirectory"
        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: testDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        let callers = try sourceFiles.filter { file in
            try String(contentsOf: file, encoding: .utf8).contains(helperCall)
        }
        #expect(!callers.isEmpty)
        for caller in callers {
            let source = try String(contentsOf: caller, encoding: .utf8)
            #expect(source.contains("extension SessionPersistenceSerializationDomainTests"))
        }
    }
}
