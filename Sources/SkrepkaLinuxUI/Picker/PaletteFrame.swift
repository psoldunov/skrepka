/// Where the palette's panel sits on the output it opens on, in that output's
/// logical pixels — the answer ``PaletteMetrics/frame(wantedHeight:outputWidth:outputHeight:)``
/// gives and the overlay window lays its panel out by.
public struct PaletteFrame: Equatable, Sendable {
    public let x: Int32
    public let y: Int32
    public let width: Int32
    public let height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
