import Foundation

enum PastedImageFile {
    static let directoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("awesomux-pasted-images", isDirectory: true)

    static func materialize(_ data: Data) throws -> URL {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let url =
            directoryURL
            .appendingPathComponent("pasted-image-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func cleanup(olderThan cutoff: Date) {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        else {
            return
        }

        for url in urls where url.pathExtension.lowercased() == "png" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let modificationDate = values?.contentModificationDate,
                modificationDate < cutoff
            else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
