import Testing
@testable import awesoMux

@Suite("WorkspaceGroupNameDraft")
struct WorkspaceGroupNameDraftTests {
    @Test("unchanged valid name has no feedback")
    func unchangedName() {
        let draft = WorkspaceGroupNameDraft(
            typedName: "Field Ops",
            existingGroupNames: ["Personal"]
        )

        #expect(draft.canSubmit)
        #expect(draft.sanitizedName == "Field Ops")
        #expect(draft.sanitizationFeedback == nil)
    }

    @Test("joiner removal previews the exact saved Persian name")
    func joinerRemoval() throws {
        let draft = WorkspaceGroupNameDraft(
            typedName: "می\u{200C}روم",
            existingGroupNames: []
        )

        let feedback = try #require(draft.sanitizationFeedback)
        #expect(draft.canSubmit)
        #expect(draft.sanitizedName == "میروم")
        #expect(feedback.contains("\u{2068}میروم\u{2069}"))
    }

    @Test("directional hint removal previews the exact saved RTL name")
    func directionalHintRemoval() throws {
        let draft = WorkspaceGroupNameDraft(
            typedName: "عملیات\u{200F}",
            existingGroupNames: []
        )

        let feedback = try #require(draft.sanitizationFeedback)
        #expect(draft.canSubmit)
        #expect(draft.sanitizedName == "عملیات")
        #expect(feedback.contains("\u{2068}عملیات\u{2069}"))
    }

    @Test("trimmed name previews the exact saved form")
    func trimmedName() throws {
        let draft = WorkspaceGroupNameDraft(
            typedName: "  Field Ops  ",
            existingGroupNames: []
        )

        let feedback = try #require(draft.sanitizationFeedback)
        #expect(draft.sanitizedName == "Field Ops")
        #expect(feedback.contains("\u{2068}Field Ops\u{2069}"))
    }

    @Test("normalization changes are detected even when Swift strings compare equal")
    func normalizationChange() {
        let draft = WorkspaceGroupNameDraft(
            typedName: "Cafe\u{301}",
            existingGroupNames: []
        )

        #expect(draft.typedName == draft.sanitizedName)
        #expect(draft.sanitizationFeedback != nil)
    }

    @Test(
        "invalid name shows validation instead of saved-form feedback",
        arguments: [
            ("\u{200C}\u{200D}", [String]()),
            ("new", ["NEW"]),
            ("pаypal", [String]()),
        ])
    func invalidName(typedName: String, existingGroupNames: [String]) {
        let draft = WorkspaceGroupNameDraft(
            typedName: typedName,
            existingGroupNames: existingGroupNames
        )

        #expect(!draft.canSubmit)
        #expect(draft.validationMessage != nil)
        #expect(draft.sanitizationFeedback == nil)
    }
}
