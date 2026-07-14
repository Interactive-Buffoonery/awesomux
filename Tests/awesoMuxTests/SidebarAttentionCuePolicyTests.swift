import Testing
@testable import awesoMux

@Suite("Sidebar attention cue policy")
struct SidebarAttentionCuePolicyTests {
    @Test("Durable acknowledgement and unread notifications both count as attention")
    func durableAttentionSources() {
        #expect(
            SidebarAttentionCuePolicy.hasAttention(
                needsAcknowledgement: true,
                unreadNotificationCount: 0
            ))
        #expect(
            SidebarAttentionCuePolicy.hasAttention(
                needsAcknowledgement: false,
                unreadNotificationCount: 1
            ))
        #expect(
            !SidebarAttentionCuePolicy.hasAttention(
                needsAcknowledgement: false,
                unreadNotificationCount: 0
            ))
    }

    @Test("Attention glow appears only for a persistently hidden sidebar with attention")
    func attentionGlowRequiresHiddenSidebarAndAttention() {
        #expect(SidebarAttentionCuePolicy.shouldGlow(isPersistentlyHidden: true, hasAttention: true))
        #expect(!SidebarAttentionCuePolicy.shouldGlow(isPersistentlyHidden: false, hasAttention: true))
        #expect(!SidebarAttentionCuePolicy.shouldGlow(isPersistentlyHidden: true, hasAttention: false))
    }

    @Test("Ordinary cue strength clamps and attention stays full strength")
    func cueStrength() {
        #expect(SidebarAttentionCuePolicy.visualStrength(intensity: -1, attention: false) == 0)
        #expect(SidebarAttentionCuePolicy.visualStrength(intensity: 0.42, attention: false) == 0.42)
        #expect(SidebarAttentionCuePolicy.visualStrength(intensity: 2, attention: false) == 1)
        #expect(SidebarAttentionCuePolicy.visualStrength(intensity: 0, attention: true) == 1)
    }

    @Test("Visibility title describes the next action")
    func visibilityTitleDescribesNextAction() {
        #expect(SidebarVisibilityActionTitle.resolve(isHidden: false) == "Hide Sidebar")
        #expect(SidebarVisibilityActionTitle.resolve(isHidden: true) == "Show Sidebar")
    }
}
