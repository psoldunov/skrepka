import CGtk4

struct TrayPixmap: Sendable, Equatable {
    let width: Int32
    let height: Int32
    let argb: [UInt8]

    var dbusValue: DBusValue {
        .tuple([
            .int32(width),
            .int32(height),
            .array(elementSignature: "y", values: argb.map(DBusValue.byte)),
        ])
    }

    static func render(size: Int32) -> TrayPixmap? {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, size, size) else { return nil }
        defer { cairo_surface_destroy(surface) }
        guard cairo_surface_status(surface) == CAIRO_STATUS_SUCCESS, let cairo = cairo_create(surface) else {
            return nil
        }
        defer { cairo_destroy(cairo) }
        cairo_set_operator(cairo, CAIRO_OPERATOR_CLEAR)
        cairo_paint(cairo)
        cairo_set_operator(cairo, CAIRO_OPERATOR_OVER)
        // 80% of the 0.76-wide mark the 0.12 inset used to leave, to match the
        // tray SVG: (1 - 0.76 × 0.8) / 2.
        let inset = Double(size) * 0.196
        // Only drawn when the host cannot find `skrepka-tray` in the icon
        // theme — the SVG follows the panel's text colour, and this cannot know
        // it. So a light mark with a dark edge, which reads on either: the
        // near-black mark 0.2.1 drew vanished on a dark panel, SteamOS's
        // default, and a plain light one would vanish on Breeze's light one.
        MarkRenderer.outlinedMark(
            cairo,
            in: .init(
                x: inset,
                y: inset,
                width: Double(size) - inset * 2,
                height: Double(size) - inset * 2
            ),
            fill: RGBColor(red: 0.93, green: 0.93, blue: 0.95),
            edge: RGBColor(red: 0.16, green: 0.16, blue: 0.18),
            edgeWidth: max(1.5, Double(size) / 14)
        )
        cairo_surface_flush(surface)
        guard let data = cairo_image_surface_get_data(surface) else { return nil }
        let stride = Int(cairo_image_surface_get_stride(surface))
        return TrayPixmap(
            width: size,
            height: size,
            argb: networkARGB(fromNativeARGB32: data, width: Int(size), height: Int(size), stride: stride)
        )
    }

    /// Cairo's native-endian, premultiplied ARGB32 as the StatusNotifierItem
    /// spec's network-order, straight-alpha ARGB.
    ///
    /// Un-premultiplied because Plasma loads the bytes as
    /// `QImage::Format_ARGB32`, which is straight alpha: premultiplied colour
    /// read that way darkens every antialiased edge.
    static func networkARGB(
        fromNativeARGB32 bytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int
    ) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bytes + y * stride + x * 4
                #if _endian(little)
                    let (alpha, red, green, blue) = (pixel[3], pixel[2], pixel[1], pixel[0])
                #else
                    let (alpha, red, green, blue) = (pixel[0], pixel[1], pixel[2], pixel[3])
                #endif
                output.append(contentsOf: [
                    alpha, straight(red, alpha), straight(green, alpha), straight(blue, alpha),
                ])
            }
        }
        return output
    }

    /// One premultiplied channel divided back out by its alpha, rounded.
    static func straight(_ channel: UInt8, _ alpha: UInt8) -> UInt8 {
        guard alpha > 0 else { return 0 }
        let value = (Int(channel) * 255 + Int(alpha) / 2) / Int(alpha)
        return UInt8(min(255, value))
    }
}
