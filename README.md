# Screenshot Clip + Copy Path

Two small helpers for macOS.

1. **Screenshot Clip.** After you take a screenshot with ⌘⇧3, ⌘⇧4 or ⌘⇧5, it is on the clipboard right away, both as the picture and as its file path. Pasting (⌘V) into an app that takes pictures (chat apps, mail, browsers, Word) gives the picture. Pasting into a text-only place such as Terminal gives the full file path. The screenshot file is still saved as usual.
2. **Copy Path.** Finder's right-click menu gets a "Copy Path" item at the top level. On files it copies their full paths, one per line. On the empty area of a folder window it copies that folder's path.

## How it works

**Screenshot Clip** is a small background app that starts at login. It watches the folder macOS saves screenshots to (⌘⇧5 → Options → Save to; the Desktop by default). It only reacts to screenshots taken on this Mac: macOS marks screenshots and writes them in a particular way. Files that other computers sync into the same folder, for example through Dropbox, are ignored. For each screenshot it puts three things on the clipboard: the picture, a file reference, and the path as text. Each app takes the kind it supports.

**Copy Path** is a Finder extension, the same mechanism that Dropbox and OneDrive use for their right-click items.

## Requirements

- macOS 13 or newer.
- Apple's Command Line Tools, for the Swift compiler. If they are missing, run `xcode-select --install`.

## Install

```sh
git clone https://github.com/Haoxi-Yuan/screenshot-clip.git
cd screenshot-clip
zsh install.sh            # both helpers
zsh install.sh clip       # only Screenshot Clip
zsh install.sh finder     # only Copy Path
```

Everything is built on your Mac and installed in `~/Applications`.

- The first time you take a screenshot, macOS asks whether "Screenshot Clip" may access the folder where screenshots are saved (for example "files in your Desktop folder"). Click **Allow**. Until you answer, nothing is copied.
- Copy Path appears in Finder's right-click menu right away. If it does not, open System Settings → General → Login Items & Extensions, and turn on Copy Path under the Finder extensions.

## Tips

- **Turn off the floating thumbnail** (⌘⇧5 → Options → Show Floating Thumbnail). While it is on, macOS saves the file only when the thumbnail goes away, about 5 seconds later, so the clipboard is filled 5 seconds later too.
- **Dropbox "Save screenshots to Dropbox".** With this feature, Dropbox moves each screenshot from the Desktop into Dropbox and then puts a share link on the clipboard, replacing the screenshot. The simplest fix is to save screenshots directly into your Dropbox screenshots folder (⌘⇧5 → Options → Other Location…). Dropbox only acts on screenshots saved to the Desktop, so it then just syncs them and leaves the clipboard alone. Then restart Screenshot Clip (next tip).
  If you prefer to keep Dropbox's feature, install with `zsh install.sh clip --follow "<your Dropbox screenshots folder>"`. The clipboard path then follows the move, and Dropbox's link is replaced with the screenshot again during the first 60 seconds.
- **After changing where screenshots are saved**, restart Screenshot Clip:
  `launchctl kickstart -k gui/$UID/com.haoxiyuan.screenshot-clip`
- **Log:** `~/Library/Logs/ScreenshotClip.log` shows each screenshot that was copied.
- Reinstalling Screenshot Clip makes macOS ask for folder access again, because the app is signed locally on your Mac.

## Uninstall

```sh
zsh uninstall.sh
```

## License

MIT, see [LICENSE](LICENSE).
