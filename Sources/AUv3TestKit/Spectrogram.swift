import Foundation
import Accelerate
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// A picture of a scenario's sound, for a person or an agent to look at: time across,
/// frequency up (on a log scale, 30 Hz to 20 kHz), brightness for level. Each step
/// starts at a numbered line. A click is a thin vertical line; zipper noise, a sweep
/// drawn as stairs; aliasing, lines that fold back down; a cut, a sudden dark edge.
enum Spectrogram {
    static let fftSize = 2048
    static let height = 480
    static let maxWidth = 2400
    static let marginLeft = 56, marginBottom = 28, marginTop = 22

    /// Draws `samples` and writes a PNG. Returns a problem, or nil when it's saved.
    static func write(_ samples: [Float], sampleRate: Double, steps: [Int], to url: URL) -> String? {
        guard samples.count >= fftSize else { return "too little audio to draw" }
        guard let dft = vDSP.DFT(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self) else {
            return "couldn't set up the FFT"
        }
        let hop = max(256, (samples.count - fftSize) / maxWidth + 1)
        let columns = (samples.count - fftSize) / hop + 1
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: fftSize)
        let binHz = sampleRate / Double(fftSize)
        let low = log2(30.0), high = log2(min(20_000, sampleRate / 2))
        // Which FFT bin each pixel row shows, bottom row first.
        let rowBins: [Int] = (0..<height).map { row in
            let hz = pow(2, low + (high - low) * Double(row) / Double(height - 1))
            return min(fftSize / 2 - 1, max(1, Int((hz / binHz).rounded())))
        }

        let plotWidth = columns
        let width = marginLeft + plotWidth + 8
        let totalHeight = marginTop + height + marginBottom
        guard let context = CGContext(data: nil, width: width, height: totalHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return "couldn't make an image" }
        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: totalHeight))
        let bytesPerRow = context.bytesPerRow

        // Levels relative to full scale: a full-scale sine reads about 0 dB.
        let scale = 4 / Float(fftSize)
        for column in 0..<columns {
            let start = column * hop
            let frame = vDSP.multiply(Array(samples[start..<(start + fftSize)]), window)
            let (real, imaginary) = dft.transform(inputReal: frame, inputImaginary: zeros)
            for row in 0..<height {
                let bin = rowBins[row]
                let magnitude = sqrt(real[bin] * real[bin] + imaginary[bin] * imaginary[bin]) * scale
                let db = magnitude > 0 ? 20 * log10(magnitude) : -120
                let (r, g, b) = color(level: (db + 100) / 100)
                // Bitmap rows run from the top.
                let y = marginTop + (height - 1 - row)
                let offset = y * bytesPerRow + (marginLeft + column) * 4
                pixels[offset] = r; pixels[offset + 1] = g; pixels[offset + 2] = b; pixels[offset + 3] = 255
            }
        }

        // Labels and lines, in Core Graphics' bottom-up coordinates.
        let plotBottom = CGFloat(marginBottom), plotTop = CGFloat(marginBottom + height)
        func y(forHz hz: Double) -> CGFloat {
            plotBottom + CGFloat((log2(hz) - low) / (high - low)) * CGFloat(height - 1)
        }
        let grey = CGColor(red: 0.75, green: 0.75, blue: 0.78, alpha: 1)
        context.setLineWidth(1)
        for hz in [50.0, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] where log2(hz) <= high {
            let lineY = y(forHz: hz)
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
            context.stroke(CGRect(x: CGFloat(marginLeft), y: lineY, width: CGFloat(plotWidth), height: 0))
            draw(hz >= 1_000 ? "\(Int(hz / 1_000))k" : "\(Int(hz))", at: CGPoint(x: 8, y: lineY - 5), color: grey, in: context)
        }
        let seconds = Double(samples.count) / sampleRate
        let tick = seconds > 60 ? 10.0 : seconds > 20 ? 5.0 : 1.0
        for t in stride(from: 0.0, through: seconds, by: tick) {
            let x = CGFloat(marginLeft) + CGFloat(t * sampleRate / Double(hop))
            draw("\(Int(t)) s", at: CGPoint(x: x - 8, y: 8), color: grey, in: context)
        }
        for (index, frame) in steps.enumerated() {
            let x = CGFloat(marginLeft) + CGFloat(Double(frame) / Double(hop))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.55))
            context.stroke(CGRect(x: x, y: plotBottom, width: 0, height: plotTop - plotBottom))
            draw("\(index + 1)", at: CGPoint(x: x + 3, y: plotTop + 5), color: CGColor(red: 1, green: 1, blue: 1, alpha: 1), in: context)
        }

        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return "couldn't write \(url.path)"
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? nil : "couldn't write \(url.path)"
    }

    /// Dark blue through magenta and orange to pale yellow, for 0 (quiet) to 1 (loud).
    private static func color(level: Float) -> (UInt8, UInt8, UInt8) {
        let t = min(max(level, 0), 1)
        let stops: [(Float, Float, Float)] = [(0.05, 0.04, 0.10), (0.30, 0.07, 0.45), (0.80, 0.20, 0.40), (0.98, 0.55, 0.15), (1.0, 0.95, 0.70)]
        let position = t * Float(stops.count - 1)
        let i = min(Int(position), stops.count - 2)
        let f = position - Float(i)
        let a = stops[i], b = stops[i + 1]
        func byte(_ x: Float, _ y: Float) -> UInt8 { UInt8(max(0, min(255, (x + (y - x) * f) * 255))) }
        return (byte(a.0, b.0), byte(a.1, b.1), byte(a.2, b.2))
    }

    private static func draw(_ text: String, at point: CGPoint, color: CGColor, in context: CGContext) {
        let font = CTFontCreateWithName("Menlo" as CFString, 11, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        guard let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else { return }
        let line = CTLineCreateWithAttributedString(string)
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
