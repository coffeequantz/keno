import AppKit
import ImageIO

/// Read-only image tab. Decodes with ImageIO at (roughly) on-screen resolution only, so a
/// 50-megapixel photo costs a few MB instead of 200 MB, and re-decodes if the view grows.
final class ImagePreviewView: NSView {
    static let extensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "heif", "webp",
        "ico", "icns", "avif", "psd", "tga", "jp2",
    ]

    static func canOpen(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    private(set) var url: URL
    private var image: CGImage?
    private var decodedMaxPixels: CGFloat = 0
    private var pixelSize = CGSize.zero
    private var decodeGeneration = 0
    private var animatedView: NSImageView?
    private let infoLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        infoLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = .secondaryLabelColor
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        addSubview(infoLabel)
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            infoLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        loadMetadata()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called when the file changed on disk (or was renamed).
    func reload(url newURL: URL? = nil) {
        if let newURL { url = newURL }
        image = nil
        decodedMaxPixels = 0
        animatedView?.removeFromSuperview()
        animatedView = nil
        loadMetadata()
        needsLayout = true
        needsDisplay = true
    }

    /// Dimensions, type and size ("4032 × 3024  ·  HEIC  ·  2.1 MB"), shown in the status bar.
    var infoText: String { infoLabel.stringValue }

    // MARK: Metadata

    private func loadMetadata() {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else {
            errorLabel.stringValue = "Can’t display “\(url.lastPathComponent)”."
            errorLabel.isHidden = false
            infoLabel.stringValue = ""
            return
        }
        errorLabel.isHidden = true
        // EXIF orientations 5–8 rotate by 90°, so width and height swap on screen.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        pixelSize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let type = url.pathExtension.uppercased()
        let frames = CGImageSourceGetCount(source)
        infoLabel.stringValue = "\(Int(pixelSize.width)) × \(Int(pixelSize.height))  ·  \(type)  ·  \(size)"
            + (frames > 1 ? "  ·  \(frames) frames" : "")

        // Animated GIFs/PNGs: let NSImageView play them (only for reasonably small files).
        if frames > 1, bytes < 30_000_000, let anim = NSImage(contentsOf: url) {
            let v = NSImageView(image: anim)
            v.animates = true
            v.imageScaling = .scaleProportionallyDown
            v.frame = bounds.insetBy(dx: 16, dy: 32)
            v.autoresizingMask = [.width, .height]
            addSubview(v, positioned: .below, relativeTo: infoLabel)
            animatedView = v
        }
    }

    // MARK: Decoding

    override func layout() {
        super.layout()
        ensureResolution()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        ensureResolution()
    }

    /// Decodes again only when the on-screen size needs noticeably more pixels than we have.
    private func ensureResolution() {
        guard animatedView == nil, pixelSize.width > 0, bounds.width > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        let shown = displayRect().size
        let needed = min(max(pixelSize.width, pixelSize.height), max(shown.width, shown.height) * scale)
        guard image == nil || needed > decodedMaxPixels * 1.15 else { return }
        decodeGeneration += 1
        let generation = decodeGeneration
        let url = self.url
        decodedMaxPixels = needed
        DispatchQueue.global(qos: .userInitiated).async {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, // honour EXIF rotation
                kCGImageSourceThumbnailMaxPixelSize: Int(ceil(needed)),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            let decoded = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
                .flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) }
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.decodeGeneration else { return }
                self.image = decoded
                self.needsDisplay = true
            }
        }
    }

    // MARK: Drawing

    /// Actual size (1 image pixel = 1 point, like Preview), shrunk to fit if larger than the view.
    private func displayRect() -> CGRect {
        let available = bounds.insetBy(dx: 16, dy: 32)
        guard pixelSize.width > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(1, available.width / pixelSize.width, available.height / pixelSize.height)
        let size = CGSize(width: floor(pixelSize.width * scale), height: floor(pixelSize.height * scale))
        return CGRect(x: floor(bounds.midX - size.width / 2), y: floor(bounds.midY - size.height / 2),
                      width: size.width, height: size.height)
    }

    private static let checker: NSColor = {
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor(white: 0.5, alpha: 0.10).setFill()
            rect.fill()
            NSColor(white: 0.5, alpha: 0.22).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
        guard animatedView == nil, let image, let ctx = NSGraphicsContext.current else { return }
        let rect = displayRect()
        // Checkerboard shows transparency.
        Self.checker.setFill()
        rect.fill()
        // Crisp pixels for small images (icons, pixel art); smooth for everything else.
        ctx.imageInterpolation = (pixelSize.width <= 256 && rect.width >= pixelSize.width) ? .none : .high
        ctx.cgContext.draw(image, in: rect)
    }
}
