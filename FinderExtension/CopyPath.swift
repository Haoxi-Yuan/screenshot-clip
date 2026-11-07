// Finder Sync extension that adds "Copy Path" to the top level of Finder's right-click menu.
// Right-click on items: copies their full paths, one per line.
// Right-click on a folder window's background: copies that folder's path.

import Cocoa
import FinderSync

@objc(CopyPathFinderSync)
final class CopyPathFinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        let menu = NSMenu(title: "")
        let item = NSMenuItem(title: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(item)
        return menu
    }

    @objc func copyPath(_ sender: AnyObject?) {
        let controller = FIFinderSyncController.default()
        var urls = controller.selectedItemURLs() ?? []
        if urls.isEmpty, let folder = controller.targetedURL() {
            urls = [folder]
        }
        guard !urls.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }
}
