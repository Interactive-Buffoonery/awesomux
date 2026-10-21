import AwesoMuxCore
import Testing
@testable import awesoMux

@Suite("Document oversize policy")
struct DocumentOversizePolicyTests {
    @Test(arguments: [
        (DocumentLoader.LoadResult.rejected(.tooLarge), true, false, DocumentOversizePolicy.Decision.retainRender),
        (.rejected(.tooLarge), true, true, .retainRender),
        (.rejected(.tooLarge), false, false, .apply),
        (.readError("boom"), true, false, .apply),
        (.readError("boom"), true, true, .apply),
        (.loaded(source: "# plan\n", snapshot: nil), true, true, .settle),
        (.loaded(source: "# plan\n", snapshot: nil), true, false, .apply),
    ])
    func reloadPolicy(
        result: DocumentLoader.LoadResult, priorRender: Bool, bannerShowing: Bool,
        expected: DocumentOversizePolicy.Decision
    ) {
        #expect(
            DocumentOversizePolicy.decide(
                result: result, hasPriorRender: priorRender,
                isBannerShowing: bannerShowing) == expected)
    }
}
