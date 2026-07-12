public struct SurfaceBackingState: Equatable, Sendable {
    public let geometry: SurfaceBackingGeometry
    public let isVisible: Bool

    public init(geometry: SurfaceBackingGeometry, isVisible: Bool) {
        self.geometry = geometry
        self.isVisible = isVisible
    }
}
