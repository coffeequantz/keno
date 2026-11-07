import AppKit
import PDFKit

/// A read-only tab that shows a file instead of editing it (images, PDFs).
protocol FileViewer: NSView {
    /// Called when the file changed on disk, or with a new URL after a rename.
    func reload(url: URL?)
    /// Shown in the status bar instead of the cursor position.
    var infoText: String { get }
    /// Called when `infoText` changes without a tab switch (e.g. scrolling to another page).
    var onInfoChange: (() -> Void)? { get set }
    /// The view that should receive keyboard focus.
    var focusTarget: NSView { get }
}

extension FileViewer {
    var focusTarget: NSView { self }
}

/// Opens the viewer that fits `url`, or nil when it should open as text.
func makeFileViewer(for url: URL) -> FileViewer? {
    if ImagePreviewView.canOpen(url) { return ImagePreviewView(url: url) }
    if PDFPreviewView.canOpen(url) { return PDFPreviewView(url: url) }
    return nil
}

/// Read-only PDF tab. PDFKit draws only the visible pages, in tiles on background threads,
/// so even long documents stay light.
final class PDFPreviewView: NSView, FileViewer {
    static func canOpen(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    private(set) var url: URL
    var onInfoChange: (() -> Void)?
    private let pdfView = PDFView()
    private let errorLabel = NSTextField(labelWithString: "")
    private var fileInfo = ""

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = Theme.editorBackground
        pdfView.frame = bounds
        pdfView.autoresizingMask = [.width, .height]
        addSubview(pdfView)

        errorLabel.textColor = .secondaryLabelColor
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.isHidden = true
        addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    func reload(url newURL: URL?) {
        if let newURL { url = newURL }
        // Stay on the same page when the file is rebuilt (e.g. a LaTeX or Typst build).
        let page = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) }
        load()
        if let page, let doc = pdfView.document, doc.pageCount > 0 {
            if let p = doc.page(at: min(page, doc.pageCount - 1)) { pdfView.go(to: p) }
        }
    }

    private func load() {
        var doc = PDFDocument(url: url)
        if let locked = doc, locked.isLocked {
            errorLabel.stringValue = "“\(url.lastPathComponent)” is password-protected."
            doc = nil
        } else if doc == nil {
            errorLabel.stringValue = "Can’t display “\(url.lastPathComponent)”."
        }
        pdfView.document = doc
        pdfView.isHidden = doc == nil
        errorLabel.isHidden = doc != nil
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        fileInfo = "PDF  ·  " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        onInfoChange?()
    }

    /// "Page 3 of 12  ·  PDF  ·  1.2 MB"
    var infoText: String {
        guard let doc = pdfView.document else { return "" }
        let current = pdfView.currentPage.map { doc.index(for: $0) + 1 } ?? 1
        return "Page \(current) of \(doc.pageCount)  ·  \(fileInfo)"
    }

    @objc private func pageChanged() { onInfoChange?() }

    override func draw(_ dirtyRect: NSRect) {
        Theme.editorBackground.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    /// PDFView itself, so arrow keys, Page Up/Down and ⌘C work right away.
    var focusTarget: NSView { pdfView }
}
