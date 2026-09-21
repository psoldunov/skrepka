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
        let inset = Double(size) * 0.12
        MarkRenderer.fillMark(
            cairo,
            in: .init(
                x: inset,
                y: inset,
                width: Double(size) - inset * 2,
                height: Double(size) - inset * 2
            ),
            color: RGBColor(red: 0.17, green: 0.17, blue: 0.19)
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
                    output.append(contentsOf: [pixel[3], pixel[2], pixel[1], pixel[0]])
                #else
                    output.append(contentsOf: [pixel[0], pixel[1], pixel[2], pixel[3]])
                #endif
            }
        }
        return output
    }
}
