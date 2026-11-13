import Testing
@testable import awesoMux

struct BranchMenuLoadingTests {
    @Test func repeatedActivationDoesNotReplaceThePendingRequest() throws {
        var load = BranchMenuLoadState()
        let request = try #require({ load.begin() }())
        #expect(load.isLoading)
        #expect({ load.begin() }() == nil)
        #expect({ load.finish(request) }())
        #expect(!load.isLoading)
        #expect(!{ load.finish(request) }())
        #expect({ load.begin() }() != nil)
    }

    @Test(arguments: [true, false])
    func invalidationRejectsTheOldCompletionWithoutClearingANewerRequest(newerFinishesFirst: Bool) throws {
        var load = BranchMenuLoadState()
        let old = try #require({ load.begin() }())
        load.invalidate()
        #expect(!load.isLoading)
        let current = try #require({ load.begin() }())
        if newerFinishesFirst {
            #expect({ load.finish(current) }())
            #expect(!{ load.finish(old) }())
            #expect(!load.isLoading)
        } else {
            #expect(!{ load.finish(old) }())
            #expect(load.isLoading)
            #expect({ load.finish(current) }())
            #expect(!load.isLoading)
        }
    }

    @Test func invalidatedRequestCannotFinishAfterTeardown() throws {
        var load = BranchMenuLoadState()
        let request = try #require({ load.begin() }())
        load.invalidate()
        #expect(!{ load.finish(request) }())
        #expect(!load.isLoading)
    }
}
