import Testing
@testable import awesoMux

@Suite("Remote additional SSH features sheet presenter")
struct RemoteAdditionalSSHFeaturesSheetPresenterTests {
    @Test("explicit install resolves after the sheet dismisses")
    @MainActor
    func explicitInstallResolvesAfterDismissal() async throws {
        let presenter = RemoteAdditionalSSHFeaturesSheetPresenter()
        let result = Task { @MainActor in
            await presenter.present(
                action: .install,
                destination: "pangolin",
                platform: "Linux · x86_64",
                installPath: "~/.awesomux/bin/awesomux-bridge-helper"
            )
        }
        await Task.yield()
        let request = try #require(presenter.request)

        presenter.choose(requestID: request.id, install: true)
        #expect(presenter.request == nil)
        presenter.presentationDidDismiss()

        #expect(await result.value)
    }

    @Test("implicit dismissal continues without installing")
    @MainActor
    func implicitDismissalContinuesWithoutInstalling() async throws {
        let presenter = RemoteAdditionalSSHFeaturesSheetPresenter()
        let result = Task { @MainActor in
            await presenter.present(
                action: .update,
                destination: "berrypie",
                platform: "Linux · aarch64",
                installPath: "~/.awesomux/bin/awesomux-bridge-helper"
            )
        }
        await Task.yield()
        _ = try #require(presenter.request)

        presenter.request = nil
        presenter.presentationDidDismiss()

        #expect(!(await result.value))
    }

    @Test("a second request is rejected while a sheet is active")
    @MainActor
    func concurrentRequestIsRejected() async throws {
        let presenter = RemoteAdditionalSSHFeaturesSheetPresenter()
        let first = Task { @MainActor in
            await presenter.present(
                action: .install,
                destination: "pangolin",
                platform: "Linux · x86_64",
                installPath: "helper"
            )
        }
        await Task.yield()
        let request = try #require(presenter.request)

        let second = await presenter.present(
            action: .install,
            destination: "berrypie",
            platform: "Linux · aarch64",
            installPath: "helper"
        )
        #expect(!second)

        presenter.choose(requestID: request.id, install: false)
        presenter.presentationDidDismiss()
        #expect(!(await first.value))
    }
}
