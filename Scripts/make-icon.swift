// Draws the Vitals app icon and writes it as a PNG at any size.
//
//   make-icon <size> <out.png>            full-bleed, for the .icns
//   make-icon --rounded <size> <out.png>  masked to a squircle, for the README
//
// Run via Scripts/make-icon.sh, which renders every size macOS asks for and
// packs them into Resources/Vitals.icns.
//
// The mark is an ECG complex: the app is called Vitals, and a pulse trace is
// also the shape it draws all day in its own sparklines. The colour ramp is
// the app's own — green through cyan to blue are the ends of the palette the
// network sparklines already use.
//
// Two things here are not obvious and were both settled by rendering the
// result and looking at it rather than by reasoning about the docs.
//
// The artwork is full bleed, with no rounded corners of its own. macOS 26
// masks a legacy .icns into the system squircle itself, so art that draws its
// own squircle gets composited *inside* the system's container and comes out
// as an icon within an icon, sitting on a light plate. Drawing a squircle at
// full canvas size is not enough either — it is a slightly different curve
// from the system's, and the difference shows as a pale fringe along the
// edges. A plain filled square is the only version the mask lands on cleanly.
// The cost is that on macOS 14 and 15, which do no masking, the icon is a
// square rather than a squircle.
//
// Nothing here is one drawing scaled down. An icon that is merely resampled
// turns to mush at 16pt, where the mark gets about ten usable pixels of width,
// so the geometry changes per size band: the full complex with a bloom where
// there is room for it, a single bold spike and no bloom where the bloom would
// only be grey haze.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Colour

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
    )!
}

let bodyRamp = [rgb(0x2B3340), rgb(0x161B22), rgb(0x0B0E13)]
let traceRamp = [rgb(0x34D399), rgb(0x22D3EE), rgb(0x60A5FA)]

// MARK: - Geometry

/// A superellipse, which is what Apple's "continuous" rounded corners are.
/// Only used for the standalone README render; the .icns art is square and
/// lets the system apply its own mask.
func squirclePath(in rect: CGRect, n: CGFloat = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = rect.midY + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.addLine(to: CGPoint(x: x, y: y))
        }
    }
    path.closeSubpath()
    return path
}

/// The full ECG complex: flat baseline, a small P wave, the tall spike, the
/// overshoot below the line, then flat again. Normalised, y from the top.
let fullPulse: [(CGFloat, CGFloat)] = [
    (0.00, 0.56), (0.21, 0.56), (0.29, 0.47), (0.37, 0.61),
    (0.50, 0.13), (0.60, 0.85), (0.69, 0.56), (1.00, 0.56),
]

/// One spike and a baseline. At 16pt every extra inflection costs about two
/// pixels and buys nothing; this still reads unmistakably as a pulse.
let simplePulse: [(CGFloat, CGFloat)] = [
    (0.00, 0.58), (0.34, 0.58), (0.50, 0.16), (0.66, 0.58), (1.00, 0.58),
]

func pulsePath(_ points: [(CGFloat, CGFloat)], in rect: CGRect) -> CGPath {
    let path = CGMutablePath()
    for (i, p) in points.enumerated() {
        let pt = CGPoint(x: rect.minX + p.0 * rect.width, y: rect.maxY - p.1 * rect.height)
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    return path
}

// MARK: - Drawing

func drawIcon(_ ctx: CGContext, size s: CGFloat, rounded: Bool) {
    let body = CGRect(x: 0, y: 0, width: s, height: s)

    // Below this the bloom stops reading as light and starts reading as haze,
    // and the small inflections in the complex stop resolving at all.
    let detailed = s >= 64

    ctx.saveGState()
    ctx.addPath(rounded ? squirclePath(in: body) : CGPath(rect: body, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(bodyRamp),
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.minY),
        options: []
    )
    ctx.restoreGState()

    let area = body.insetBy(dx: s * 0.17, dy: s * (detailed ? 0.33 : 0.30))
    let stroke = detailed ? s * 0.072 : max(s * 0.105, 1.5)
    let line = pulsePath(detailed ? fullPulse : simplePulse, in: area)

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    if detailed {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: stroke * 1.9, color: rgb(0x34D399, 0.55))
        ctx.addPath(line)
        ctx.setLineWidth(stroke)
        ctx.setStrokeColor(traceRamp[0])
        ctx.strokePath()
        ctx.restoreGState()
    }

    ctx.addPath(line)
    ctx.setLineWidth(stroke)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(traceRamp),
        start: CGPoint(x: area.minX, y: area.midY),
        end: CGPoint(x: area.maxX, y: area.midY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

// MARK: - Entry point

var args = Array(CommandLine.arguments.dropFirst())
var rounded = false
if let i = args.firstIndex(of: "--rounded") {
    rounded = true
    args.remove(at: i)
}

guard args.count == 2, let size = Int(args[0]), size > 0 else {
    FileHandle.standardError.write(Data("usage: make-icon [--rounded] <size> <out.png>\n".utf8))
    exit(1)
}

let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high
drawIcon(ctx, size: CGFloat(size), rounded: rounded)

let url = URL(fileURLWithPath: args[1])
guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not encode \(url.path)\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("could not write \(url.path)\n".utf8))
    exit(1)
}
