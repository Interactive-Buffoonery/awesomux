import AppKit
import AwesoMuxConfig
import QuartzCore

enum SidebarOverlayTransition: Equatable {
    case immediate
    case hover

    var duration: TimeInterval {
        switch self {
        case .immediate: 0
        case .hover: 0.140
        }
    }
}

@MainActor
final class SidebarOverlayAnimator {
    typealias AnimationRunner = (
        _ layer: CALayer,
        _ fromTranslationX: CGFloat,
        _ toTranslationX: CGFloat,
        _ duration: TimeInterval,
        _ completion: @escaping () -> Void
    ) -> Void

    static let animationKey = "awesomux.sidebarOverlay.translation"
    static let presentedTranslation: CGFloat = 0
    static let timingFunctionName = CAMediaTimingFunctionName.easeInEaseOut

    private let layer: CALayer
    private let presentationTranslation: () -> CGFloat?
    private let animationRunner: AnimationRunner
    private var generation: UInt = 0
    private var requestedPresented: Bool?
    private var activeTargetTranslation: CGFloat?
    private var fallbackTranslation: CGFloat = 0

    var requestedPresentedState: Bool? { requestedPresented }
    var isAnimating: Bool { activeTargetTranslation != nil }
    var currentTranslation: CGFloat {
        finitePresentationTranslation ?? fallbackTranslation
    }

    init(
        layer: CALayer,
        presentationTranslation: (() -> CGFloat?)? = nil,
        animationRunner: AnimationRunner? = nil
    ) {
        self.layer = layer
        self.presentationTranslation =
            presentationTranslation ?? {
                layer.presentation()?.transform.m41
            }
        self.animationRunner = animationRunner ?? Self.runAnimation
    }

    func setPresented(
        _ presented: Bool,
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition,
        transition: SidebarOverlayTransition,
        reduceMotion: Bool,
        completion: @escaping (UInt) -> Void
    ) {
        setPresented(
            presented,
            width: width,
            position: position,
            transition: transition,
            reduceMotion: reduceMotion,
            currentOverride: nil,
            completion: completion)
    }

    private func setPresented(
        _ presented: Bool,
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition,
        transition: SidebarOverlayTransition,
        reduceMotion: Bool,
        currentOverride: CGFloat?,
        completion: @escaping (UInt) -> Void
    ) {
        let target =
            presented
            ? Self.presentedTranslation
            : Self.hiddenTranslation(width: width, position: position)
        if requestedPresented == presented, activeTargetTranslation == target { return }

        let hadRequest = requestedPresented != nil
        requestedPresented = presented
        generation &+= 1
        let requestGeneration = generation

        let current: CGFloat
        if let currentOverride {
            current = currentOverride
        } else if let presentation = finitePresentationTranslation {
            current = presentation
        } else if !hadRequest, presented {
            current = Self.hiddenTranslation(width: width, position: position)
        } else {
            current = layer.transform.m41
        }

        layer.removeAnimation(forKey: Self.animationKey)
        setModelTranslation(target)

        guard !reduceMotion, transition.duration > 0, current != target else {
            activeTargetTranslation = nil
            fallbackTranslation = target
            completion(requestGeneration)
            return
        }

        activeTargetTranslation = target
        fallbackTranslation = current
        animationRunner(layer, current, target, transition.duration) { [weak self] in
            guard let self, self.generation == requestGeneration else { return }
            self.activeTargetTranslation = nil
            self.fallbackTranslation = target
            self.setModelTranslation(target)
            completion(requestGeneration)
        }
    }

    func cancelAndSettle(
        presented: Bool,
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition
    ) {
        generation &+= 1
        requestedPresented = presented
        activeTargetTranslation = nil
        fallbackTranslation =
            presented
            ? Self.presentedTranslation
            : Self.hiddenTranslation(width: width, position: position)
        layer.removeAnimation(forKey: Self.animationKey)
        setModelTranslation(fallbackTranslation)
    }

    func reframe(
        fromWidth oldWidth: CGFloat,
        toWidth newWidth: CGFloat,
        position: AppearanceConfig.SidebarPosition,
        transition: SidebarOverlayTransition,
        reduceMotion: Bool,
        completion: @escaping (UInt) -> Void
    ) {
        guard let requestedPresented else { return }
        let current = finitePresentationTranslation ?? fallbackTranslation
        let fraction = Self.visibleFraction(
            translationX: current,
            hiddenTranslationX: Self.hiddenTranslation(width: oldWidth, position: position))
        generation &+= 1
        activeTargetTranslation = nil
        layer.removeAnimation(forKey: Self.animationKey)
        let mappedTranslation = Self.translation(
            width: newWidth, position: position, visibleFraction: fraction)
        fallbackTranslation = mappedTranslation
        setModelTranslation(mappedTranslation)
        self.requestedPresented = nil
        setPresented(
            requestedPresented,
            width: newWidth,
            position: position,
            transition: transition,
            reduceMotion: reduceMotion,
            currentOverride: mappedTranslation,
            completion: completion)
    }

    static func hiddenTranslation(
        width: CGFloat, position: AppearanceConfig.SidebarPosition
    ) -> CGFloat {
        let safeWidth = width.isFinite ? max(0, width) : 0
        return position == .left ? -safeWidth : safeWidth
    }

    static func visibleFraction(
        translationX: CGFloat, hiddenTranslationX: CGFloat
    ) -> CGFloat {
        guard translationX.isFinite, hiddenTranslationX.isFinite, hiddenTranslationX != 0 else {
            return 0
        }
        return min(1, max(0, 1 - translationX / hiddenTranslationX))
    }

    static func translation(
        width: CGFloat,
        position: AppearanceConfig.SidebarPosition,
        visibleFraction: CGFloat
    ) -> CGFloat {
        let fraction = visibleFraction.isFinite ? min(1, max(0, visibleFraction)) : 0
        return hiddenTranslation(width: width, position: position) * (1 - fraction)
    }

    private func setModelTranslation(_ translation: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(translation, 0, 0)
        CATransaction.commit()
    }

    private var finitePresentationTranslation: CGFloat? {
        guard let translation = presentationTranslation(), translation.isFinite else { return nil }
        return translation
    }

    private static func runAnimation(
        layer: CALayer,
        from: CGFloat,
        to: CGFloat,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timingFunctionName)
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(animation, forKey: animationKey)
        CATransaction.commit()
    }
}
