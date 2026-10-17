import Foundation

public enum WorkspaceEmoji {
    public static func validated(_ raw: String?) -> String? {
        guard let raw, raw.unicodeScalars.prefix(33).count <= 32 else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count == 1, let first = value.unicodeScalars.first,
            first.properties.isEmoji, !first.properties.isEmojiModifier,
            first.properties.isEmojiPresentation
                || value.unicodeScalars.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 || $0.properties.isEmojiModifier }),
            value.unicodeScalars.allSatisfy({
                $0.properties.isEmoji || $0.value == 0xFE0F || $0.value == 0x200D
                    || $0.value == 0x20E3 || (0xE0020...0xE007F).contains($0.value)
            })
        else { return nil }

        let scalars = Array(value.unicodeScalars)
        guard scalars.filter({ $0.value == 0x200D }).count <= 3 else { return nil }
        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isEmojiModifier {
                guard index > 0, scalars[index - 1].properties.isEmojiModifierBase else { return nil }
            }
            if scalar.value == 0xFE0F {
                guard index > 0, scalars[index - 1].properties.isEmoji,
                    !scalars[index - 1].properties.isEmojiModifier
                else { return nil }
            }
            if scalar.value == 0x20E3 {
                guard first.value < 128, index == scalars.count - 1,
                    scalars.count == 2 || (scalars.count == 3 && scalars[1].value == 0xFE0F)
                else { return nil }
            }
        }
        if (0x1F1E6...0x1F1FF).contains(first.value) {
            guard scalars.count == 2, scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0.value) })
            else { return nil }
        }
        if first.value < 128 {
            guard scalars.last?.value == 0x20E3 else { return nil }
        }
        if scalars.contains(where: { (0xE0020...0xE007F).contains($0.value) }) {
            guard first.value == 0x1F3F4, scalars.count == 7, scalars.last?.value == 0xE007F,
                scalars.dropFirst().dropLast().allSatisfy({ (0xE0061...0xE007A).contains($0.value) })
            else { return nil }
            let code = String(String.UnicodeScalarView(scalars.dropFirst().dropLast().compactMap { Unicode.Scalar($0.value - 0xE0000) }))
            // Only the three RGI subdivision flags may carry invisible tag characters.
            guard ["gbeng", "gbsct", "gbwls"].contains(code) else { return nil }
        }
        // shortcut: Unicode structure is checked without an RGI catalog; add one if unsupported pasted sequences become a problem.
        return value
    }
}
