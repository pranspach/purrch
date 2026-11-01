import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// `Purrch --record-demo <file.gif>` drives the real panel through a script and saves it as a GIF.
/// It only opens widgets that show no personal data, so the result is safe to publish.
final class DemoRecorder {
    private struct Frame {
        let image: CGImage
        let data: Data
        var duration: Double
    }

    private let output: URL
    private var frames: [Frame] = []
    private var isCapturing = false

    private static let canvas = CGSize(width: 560, height: 400)
    private static let scale: CGFloat = 1.5
    private static let frameInterval = 0.1

    init(output: URL) {
        self.output = output
    }

    func run() {
        Task { @MainActor in
            let previousSelection = UserDefaults.standard.string(forKey: "selectedWidget")
            self.startCapturing()
            await self.script()
            self.isCapturing = false
            self.write()
            UserDefaults.standard.set(previousSelection, forKey: "selectedWidget")
            NSApp.terminate(nil)
        }
    }

    @MainActor private func script() async {
        let services = Services.shared
        let notch = services.notch
        let widget = { (id: String) in services.widgets.widgets.first { $0.id == id } }
        guard let timer = widget("timer"), let caffeinate = widget("caffeinate"), let focus = widget("focus") else { return }

        await wait(1)
        notch.open(timer)
        notch.isPinned = true
        await wait(1.2)
        _ = try? await services.webViews.view(for: timer).evaluateJavaScript("toggle(); 0")
        await wait(1.6)

        notch.hoverTab(caffeinate.id, inside: true)
        await wait(0.5)
        notch.hoverTab(caffeinate.id, inside: false)
        notch.open(caffeinate)
        await wait(1.4)

        notch.hoverTab(focus.id, inside: true)
        await wait(0.5)
        notch.hoverTab(focus.id, inside: false)
        notch.open(focus)
        await wait(1)
        _ = try? await services.webViews.view(for: focus).evaluateJavaScript("begin(25); 0")
        await wait(1.6)

        notch.openSearch()
        await wait(0.5)
        await type("2^10 / (3+5)")
        await wait(1.6)
        await type("weather in Berlin")
        for _ in 0..<40 where !notch.results.contains(where: { $0.id == "weather" }) {
            await wait(0.1)
        }
        await wait(1.8)
        await type("a countdown to Friday")
        await wait(2)

        notch.collapse()
        await wait(1)
    }

    @MainActor private func type(_ text: String) async {
        for length in 0...text.count {
            Services.shared.notch.query = String(text.prefix(length))
            await wait(0.05)
        }
    }

    @MainActor private func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @MainActor private func startCapturing() {
        isCapturing = true
        Task { @MainActor in
            while self.isCapturing {
                self.capture()
                try? await Task.sleep(for: .seconds(Self.frameInterval))
            }
        }
    }

    /// Draws the panel hanging from the top of a plain backdrop, so size changes stay in one frame.
    @MainActor private func capture() {
        guard let view = Services.shared.notch.panel?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let panel = bitmap.cgImage else { return }

        let width = Int(Self.canvas.width * Self.scale)
        let height = Int(Self.canvas.height * Self.scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

        context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let size = CGSize(width: view.bounds.width * Self.scale, height: view.bounds.height * Self.scale)
        context.interpolationQuality = .high
        context.draw(panel, in: CGRect(x: (CGFloat(width) - size.width) / 2, y: CGFloat(height) - size.height, width: size.width, height: size.height))

        guard let image = context.makeImage(), let data = image.dataProvider?.data as Data? else { return }
        // Repeated frames just extend the last one, which keeps the file small.
        if let last = frames.indices.last, frames[last].data == data {
            frames[last].duration += Self.frameInterval
        } else {
            frames.append(Frame(image: image, data: data, duration: Self.frameInterval))
        }
    }

    private func write() {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        let loop = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, loop)
        for frame in frames {
            let properties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: frame.duration]] as CFDictionary
            CGImageDestinationAddImage(destination, frame.image, properties)
        }
        CGImageDestinationFinalize(destination)
    }
}
