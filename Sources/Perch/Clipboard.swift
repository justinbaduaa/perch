import AppKit
import UniformTypeIdentifiers

/// Copying attachments out of the thread, and pasting files and pictures into the message box.
enum Clipboard {
    /// Copies files the way Finder does, with the picture itself alongside each image, so apps that take only
    /// pictures (a browser, Figma) can paste them too.
    static func copy(_ files: [URL], to pb: NSPasteboard = .general) {
        let items = files.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
               let png = NSImage(contentsOf: url)?.tiffRepresentation.flatMap(pngData) {
                item.setData(png, forType: .png)
            }
            return item
        }
        pb.clearContents()
        pb.writeObjects(items)
    }

    /// Files to put in the message box from the clipboard: files copied in Finder or Perch, or a bare picture
    /// (a screenshot copied to the clipboard, Copy Image in a browser), saved as a PNG. Nil when the clipboard
    /// holds text, which the text field pastes as usual.
    static func pastedFiles(from pb: NSPasteboard = .general) -> [URL]? {
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files }
        guard pb.string(forType: .string) == nil,
              let png = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap(pngData) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let url = dir.appending(path: "Pasted image.png")
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? png.write(to: url)) != nil else { return nil }
        return [url]
    }

    private static func pngData(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }
}
