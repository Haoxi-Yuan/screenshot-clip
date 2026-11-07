// Screenshot Clip
//
// Watches for new macOS screenshots (Cmd+Shift+3/4/5) and puts each one on the
// clipboard in three forms at once:
//   - the image itself       -> apps that accept images paste the picture
//   - a file reference       -> apps that accept file drops attach the file
//   - the full path as text  -> text-only inputs (Terminal) paste the path
//
// Usage: ScreenshotClip [follow-dir ...]
//   New screenshots are detected in the macOS screenshot location
//   (com.apple.screencapture "location", default ~/Desktop). Each follow-dir is a
//   folder that screenshots get moved into afterwards (e.g. Dropbox's screenshot
//   folder); when a screenshot we copied is moved there, the clipboard's path is
//   updated, but only if nothing else has been copied in the meantime.
//
// Only screenshots saved on this computer count. screencaptureui writes a hidden
// "..<name>-XXXX", renames it to ".<name>", then to "<name>" in the save folder; files
// that appear without that hidden step (for example, screenshots synced from another
// computer into a Dropbox folder) are ignored.
//
// Dropbox's "share screenshots" feature writes an empty string and then a dropbox.com
// share link to the clipboard a few seconds after each screenshot. For up to
// guardSeconds after a screenshot, such a write is replaced with the screenshot again,
// but only when it is the very next clipboard change after ours and the link points to
// this screenshot. Anything else copied in the meantime ends the guard.

import AppKit
import CoreServices
import UniformTypeIdentifiers

let screenshotAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
let trackSeconds: TimeInterval = 120  // how long a copied screenshot is followed for moves
let maxAgeSeconds: TimeInterval = 60  // files created longer ago than this are not "new"
let guardSeconds: TimeInterval = 60   // how long Dropbox's clipboard writes are undone
let guardPollSeconds = 0.05

let timestampFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "\(timestampFormat.string(from: Date())) \(message)\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
}

func normalizedDir(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        .precomposedStringWithCanonicalMapping
}

func screenshotLocation() -> String {
    if let location = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
       !location.isEmpty {
        return location
    }
    return "~/Desktop"
}

func regularFileInfo(_ path: String) -> (inode: UInt64, created: Date)? {
    var st = stat()
    guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
    let created = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec)
        + TimeInterval(st.st_birthtimespec.tv_nsec) / 1e9)
    return (UInt64(st.st_ino), created)
}

func hasAttribute(_ path: String, _ name: String) -> Bool {
    getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

/// Puts the screenshot on the general pasteboard. Returns the pasteboard change
/// count after writing, or nil if the file could not be read as an image.
func copyToClipboard(_ path: String) -> Int? {
    let url = URL(fileURLWithPath: path)
    var imageData: Data?
    for attempt in 0..<10 {
        if let data = try? Data(contentsOf: url), !data.isEmpty, NSImage(data: data) != nil {
            imageData = data
            break
        }
        if !FileManager.default.fileExists(atPath: path) {
            log("moved away before it could be read: \(path)")
            return nil
        }
        if attempt < 9 { Thread.sleep(forTimeInterval: 0.05) }
    }
    guard let imageData else {
        log("could not read image: \(path)")
        return nil
    }

    // The image type follows the file (screenshots can be saved as png, jpg, heic, pdf, tiff).
    // The pasteboard server derives TIFF/JPEG/etc. from it for apps that ask for those.
    let fileType = UTType(filenameExtension: url.pathExtension) ?? .png
    let item = NSPasteboardItem()
    item.setData(imageData, forType: NSPasteboard.PasteboardType(fileType.identifier))
    item.setString(url.absoluteString, forType: .fileURL)
    item.setString(path, forType: .string)

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    guard pasteboard.writeObjects([item]) else {
        log("clipboard write failed: \(path)")
        return nil
    }
    return pasteboard.changeCount
}

/// Lowercased letters and digits only, so "Screenshot 2026-11-07 at 2.27.32\u{202F}PM.png"
/// and Dropbox's link name "Screenshot-2026-11-07-at-2.27.32-PM.png" compare equal.
func nameKey(_ name: String) -> String {
    String(String.UnicodeScalarView(
        name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
}

/// True if the clipboard holds only text that is empty or a dropbox.com link to `name`,
/// which is what Dropbox's screenshot sharing writes.
func isDropboxScreenshotWrite(_ pasteboard: NSPasteboard, name: String) -> Bool {
    let textTypes: Set<String> = [
        "public.utf8-plain-text", "NSStringPboardType",
        "public.utf16-plain-text", "public.utf16-external-plain-text",
    ]
    let types = Set((pasteboard.types ?? []).map(\.rawValue))
    guard !types.isEmpty, types.isSubset(of: textTypes) else { return false }
    let text = (pasteboard.string(forType: .string) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return true }
    guard let url = URL(string: text), url.scheme == "https",
          let host = url.host?.lowercased(), host == "dropbox.com" || host.hasSuffix(".dropbox.com")
    else { return false }
    if nameKey(url.lastPathComponent) == nameKey(name) { return true }
    log("Dropbox link for a different file left on the clipboard: \(text)")
    return false
}

final class ScreenshotClip {
    struct Tracked {
        var path: String
        let name: String
        var inode: UInt64
        var changeCount: Int
        let copiedAt: Date
    }

    let sourceDirs: Set<String>
    let followDirs: Set<String>
    private var tracked: [Tracked] = []
    private var namesBeingSaved: [String: Date] = [:]
    private var stream: FSEventStreamRef?
    private var guardedName: String?
    private var guardUntil = Date.distantPast
    private var guardTimer: DispatchSourceTimer?

    init(sourceDirs: [String], followDirs: [String]) {
        self.sourceDirs = Set(sourceDirs)
        self.followDirs = Set(followDirs).subtracting(sourceDirs)
    }

    func start() {
        let watched = sourceDirs.union(followDirs).filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
        }
        guard !watched.isEmpty else {
            log("no existing folder to watch; exiting")
            exit(1)
        }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let clip = Unmanaged<ScreenshotClip>.fromOpaque(info).takeUnretainedValue()
            let pathList = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
            for i in 0..<count {
                clip.handle(path: pathList[i], flags: flags[i])
            }
        }
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, Array(watched) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, createFlags)
        else {
            log("could not create file event stream; exiting")
            exit(1)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
        log("watching for new screenshots in \(sourceDirs.sorted()); following moves into \(followDirs.sorted())")
    }

    func handle(path: String, flags: FSEventStreamEventFlags) {
        guard flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile) != 0 else { return }
        let name = (path as NSString).lastPathComponent.precomposedStringWithCanonicalMapping
        let dir = (path as NSString).deletingLastPathComponent.precomposedStringWithCanonicalMapping
        let inSource = sourceDirs.contains(dir)
        guard inSource || followDirs.contains(dir) else { return }  // subfolders are ignored

        let now = Date()
        tracked.removeAll { now.timeIntervalSince($0.copiedAt) > trackSeconds }
        namesBeingSaved = namesBeingSaved.filter { now.timeIntervalSince($0.value) <= trackSeconds }

        if name.hasPrefix(".") {
            // screencaptureui's hidden ".<name>": "<name>" is a screenshot saved on this
            // computer. Kept for a while in case the file is moved to a follow-dir before
            // we get to read it.
            if inSource, name.count > 1 { namesBeingSaved[String(name.dropFirst())] = now }
            return
        }

        guard let info = regularFileInfo(path), hasAttribute(path, screenshotAttribute) else { return }

        if let i = tracked.firstIndex(where: { $0.inode == info.inode || $0.name == name }) {
            guard tracked[i].path != path else { return }  // repeat event for the same file
            tracked[i].path = path
            tracked[i].inode = info.inode
            if NSPasteboard.general.changeCount == tracked[i].changeCount,
               let changeCount = copyToClipboard(path) {
                tracked[i].changeCount = changeCount
                startGuard(name: tracked[i].name)
                log("moved, clipboard path updated: \(path)")
            } else {
                log("moved, clipboard left alone because something else was copied since: \(path)")
            }
            return
        }

        guard namesBeingSaved[name] != nil else { return }  // not saved here, e.g. synced from elsewhere
        guard now.timeIntervalSince(info.created) <= maxAgeSeconds else { return }
        guard let changeCount = copyToClipboard(path) else { return }
        tracked.append(Tracked(
            path: path, name: name, inode: info.inode, changeCount: changeCount, copiedAt: now))
        startGuard(name: name)
        log("copied: \(path)")
    }

    // MARK: Undoing Dropbox's clipboard writes

    private func startGuard(name: String) {
        guardedName = name
        guardUntil = Date().addingTimeInterval(guardSeconds)
        guard guardTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + guardPollSeconds, repeating: guardPollSeconds)
        timer.setEventHandler { [weak self] in self?.checkClipboard() }
        guardTimer = timer
        timer.resume()
    }

    private func stopGuard() {
        guardTimer?.cancel()
        guardTimer = nil
        guardedName = nil
    }

    private func checkClipboard() {
        guard let name = guardedName, Date() < guardUntil,
              let i = tracked.firstIndex(where: { $0.name == name })
        else { return stopGuard() }

        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != tracked[i].changeCount else { return }  // still ours
        // A writer clears the clipboard before filling it; decide once the content is there.
        if changeCount == tracked[i].changeCount + 1, (pasteboard.types ?? []).isEmpty { return }

        // Only the single next change after ours can be Dropbox's; if more happened
        // between two polls, or it is not Dropbox's write, the person copied something else.
        if changeCount == tracked[i].changeCount + 1,
           isDropboxScreenshotWrite(pasteboard, name: name),
           let newChangeCount = copyToClipboard(tracked[i].path) {
            tracked[i].changeCount = newChangeCount
            log("replaced Dropbox's clipboard write with the screenshot again")
        } else {
            stopGuard()
        }
    }
}

let clip = ScreenshotClip(
    sourceDirs: [normalizedDir(screenshotLocation())],
    followDirs: CommandLine.arguments.dropFirst().map(normalizedDir))
clip.start()
dispatchMain()
