/// The Skrepka mark: a swirl paperclip, one continuous wire bent through three
/// U-turns, with a semicircular cap on each free end.
///
/// The artwork is an *outline* rather than a stroked centreline, because that is
/// how it was drawn — reconstructing a centreline would mean guessing at bends
/// the outline states exactly. The wire is 115.813 units wide in the 1200-unit
/// design box, which is what fixes the size of the end caps.
///
/// `scripts/paperclip.svg` is the same artwork in SVG form and is the design
/// source. `scripts/make-icon.sh` compiles *this* file into the icon renderer,
/// so the app, the menu bar and `AppIcon.icns` cannot drift apart.
///
/// Platform-free: a ``MarkPath``, not a `CGPath`. `PaperclipPath` renders it
/// with Core Graphics where that exists, and Linux draws the same value with
/// Cairo — which is what makes "the two platforms show the same mark" a fact
/// rather than an intention. OQ-12.
public enum PaperclipMark {
    /// The mark at design-box scale, top-left origin: the coordinate table in
    /// the order the SVG states it — the outer edge from the bottom-left U-turn
    /// round to the outer free end, back along the inner edge, and so on inward
    /// to the inner free end.
    public static func outline() -> MarkPath {
        var path = MarkPath.Builder()
        path.move(to: (471.701, 1111.207))
        path.curve((677.774, 906.278), (838.970, 742.464), to: (1018.270, 566.612))
        path.curve((1077.465, 504.787), (1114.957, 444.275), to: (1130.742, 385.080))
        path.curve((1158.368, 273.373), (1115.893, 176.640), to: (1041.949, 100.943))
        path.curve((970.914, 29.909), (894.947, -3.635), to: (814.047, 0.312))
        path.curve((733.147, 4.259), (653.235, 45.038), to: (574.307, 122.649))
        path.line(to: (71.146, 627.780))
        path.roundCap(to: (154.020, 708.679))
        path.line(to: (657.180, 205.521))
        path.curve((708.810, 156.434), (770.250, 110.156), to: (840.685, 116.728))
        path.curve((948.002, 131.794), (1042.776, 263.144), to: (1018.272, 355.482))
        path.curve((987.201, 437.406), (944.367, 474.771), to: (885.083, 534.053))
        path.curve((704.742, 713.933), (564.127, 853.036), to: (388.830, 1028.332))
        path.curve((322.950, 1088.531), (280.344, 1104.830), to: (219.138, 1048.064))
        path.curve((187.567, 1016.493), (173.755, 985.580), to: (177.701, 955.325))
        path.curve((182.080, 920.024), (202.064, 895.608), to: (225.056, 872.452))
        path.line(to: (684.804, 412.702))
        path.curve((705.807, 391.662), (753.640, 351.277), to: (773.597, 369.293))
        path.curve((788.908, 404.814), (749.477, 438.718), to: (730.189, 458.086))
        path.line(to: (307.929, 880.345))
        path.roundCap(to: (388.828, 963.219))
        path.line(to: (813.060, 540.961))
        path.curve((886.129, 465.596), (938.626, 373.501), to: (856.469, 288.395))
        path.curve((765.607, 210.407), (669.886, 262.472), to: (601.930, 329.832))
        path.line(to: (142.182, 789.580))
        path.curve((94.827, 836.935), (67.859, 888.238), to: (61.283, 943.488))
        path.curve((56.095, 1020.942), (91.016, 1083.116), to: (138.236, 1130.939))
        path.curve((182.621, 1175.082), (230.572, 1199.533), to: (290.172, 1200.000))
        path.curve((361.828, 1197.131), (432.284, 1149.934), to: (471.701, 1111.207))
        path.close()
        return path.build()
    }
}
