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
        #expect(draft.visualSanitizationFeedback == nil)
        #expect(draft.spokenSanitizationFeedback == nil)
    }

    @Test("joiner removal previews the exact saved Persian name")
    func joinerRemoval() throws {
        let draft = WorkspaceGroupNameDraft(
            typedName: "می\u{200C}روم",
            existingGroupNames: []
        )

        let visualFeedback = try #require(draft.visualSanitizationFeedback)
        let spokenFeedback = try #require(draft.spokenSanitizationFeedback)
        #expect(draft.canSubmit)
        #expect(draft.sanitizedName == "میروم")
        #expect(visualFeedback.contains("\u{2068}میروم\u{2069}"))
        #expect(visualFeedback.filter { $0 == "\u{2068}" }.count == 1)
        #expect(visualFeedback.filter { $0 == "\u{2069}" }.count == 1)
        #expect(!spokenFeedback.contains("\u{2068}"))
        #expect(!spokenFeedback.contains("\u{2069}"))
        #expect(spokenFeedback.contains("میروم"))
    }

    @Test("directional hint removal previews the exact saved RTL name")
    func directionalHintRemoval() throws {
        let draft = WorkspaceGroupNameDraft(
            typedName: "عملیات\u{200F}",
            existingGroupNames: []
        )

        let feedback = try #require(draft.visualSanitizationFeedback)
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

        let feedback = try #require(draft.visualSanitizationFeedback)
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
        #expect(draft.visualSanitizationFeedback != nil)
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
        #expect(draft.visualSanitizationFeedback == nil)
        #expect(draft.spokenSanitizationFeedback == nil)
    }

    @Test("remote joiner removal submits the previewed saved name")
    func remoteJoinerRemoval() throws {
        let draft = WorkspaceGroupNameDraft(
            typedName: "می\u{200C}روم",
            existingGroupNames: [],
            allowsEmptyName: true
        )

        #expect(draft.canSubmit)
        #expect(draft.sanitizedName == "میروم")
        #expect(try #require(draft.visualSanitizationFeedback).contains("\u{2068}میروم\u{2069}"))
    }

    @Test("remote empty name remains valid for the host fallback")
    func remoteEmptyName() {
        let draft = WorkspaceGroupNameDraft(
            typedName: "",
            existingGroupNames: ["Personal"],
            allowsEmptyName: true
        )

        #expect(draft.canSubmit)
        #expect(draft.sanitizedName.isEmpty)
        #expect(draft.validationMessage == nil)
        #expect(draft.visualSanitizationFeedback == nil)
    }

    @MainActor
    @Test("saved-form announcement is deduplicated until the name changes")
    func adjustmentAnnouncementDeduplication() {
        let draft = WorkspaceGroupNameDraft(
            typedName: "  Field Ops  ",
            existingGroupNames: []
        )
        let gate = WorkspaceGroupNameAdjustmentAnnouncementGate()
        var announcements: [String] = []

        gate.announceIfNeeded(for: draft) { announcements.append($0) }
        gate.announceIfNeeded(for: draft) { announcements.append($0) }
        #expect(announcements.count == 1)

        gate.editingChanged()
        gate.announceIfNeeded(for: draft) { announcements.append($0) }
        #expect(announcements.count == 2)
    }
}
