#!/bin/zsh
# Usage: ./install.sh [clip|finder|all] [--follow DIR]...   (default: all)
#   clip    builds Screenshot Clip, installs it to ~/Applications and (re)loads the
#           LaunchAgent that starts it at login. Rebuilding changes its ad-hoc signature,
#           so macOS asks again for any folder permission it needs.
#   finder  builds the Copy Path Finder extension (top level of Finder's right-click
#           menu), installs it inside ~/Applications/CopyPath.app and enables it.
#   --follow DIR  a folder that screenshots get moved into after they are saved (for
#           example by Dropbox); the clipboard path then follows the move. Repeatable.
set -euo pipefail
cd "${0:A:h}"

TARGET=all
FOLLOW=()
while (( $# )); do
    case $1 in
        clip|finder|all) TARGET=$1 ;;
        --follow) FOLLOW+=("${2:?--follow needs a folder}"); shift ;;
        *) echo "usage: $0 [clip|finder|all] [--follow DIR]..." >&2; exit 2 ;;
    esac
    shift
done

if ! command -v swiftc >/dev/null; then
    echo "The Swift compiler is missing. Install Apple's Command Line Tools first:" >&2
    echo "    xcode-select --install" >&2
    exit 1
fi
SWIFTC=(swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0")

build_clip() {
    local name=ScreenshotClip label=com.haoxiyuan.screenshot-clip
    local app="$HOME/Applications/$name.app" bundle="build/$name.app"
    local agent="$HOME/Library/LaunchAgents/$label.plist"

    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS"
    $SWIFTC -framework AppKit Sources/main.swift -o "$bundle/Contents/MacOS/$name"
    cp Info.plist "$bundle/Contents/Info.plist"
    codesign --force --sign - "$bundle"

    # Stop the running copy before replacing it.
    launchctl bootout "gui/$UID/$label" 2>/dev/null || true
    pkill -x "$name" 2>/dev/null || true

    mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
    rm -rf "$app"
    cp -R "$bundle" "$app"
    sed -e "s|__APP_BINARY__|$app/Contents/MacOS/$name|" -e "s|__HOME__|$HOME|g" \
        LaunchAgent.plist > "$agent"
    local i=1 dir
    for dir in "${FOLLOW[@]}"; do
        plutil -insert "ProgramArguments.$i" -string "${dir:a}" "$agent"
        i=$((i + 1))
    done
    launchctl bootstrap "gui/$UID" "$agent"
    echo "Installed $app and loaded $label"
}

build_finder() {
    local app="$HOME/Applications/CopyPath.app" bundle="build/CopyPath.app"
    local ext_id=com.haoxiyuan.CopyPath.FinderExtension
    local appex="$bundle/Contents/PlugIns/CopyPathExtension.appex"

    rm -rf "$bundle"
    mkdir -p "$bundle/Contents/MacOS" "$appex/Contents/MacOS"
    $SWIFTC -application-extension -parse-as-library -module-name CopyPathExtension \
        -framework Cocoa -framework FinderSync -Xlinker -e -Xlinker _NSExtensionMain \
        FinderExtension/CopyPath.swift -o "$appex/Contents/MacOS/CopyPathExtension"
    cp FinderExtension/Extension-Info.plist "$appex/Contents/Info.plist"
    $SWIFTC FinderExtension/Host.swift -o "$bundle/Contents/MacOS/CopyPath"
    cp FinderExtension/Host-Info.plist "$bundle/Contents/Info.plist"
    codesign --force --sign - --entitlements FinderExtension/Sandbox.entitlements "$appex"
    codesign --force --sign - --entitlements FinderExtension/Sandbox.entitlements "$bundle"

    # Unregister and stop the old copy before replacing it.
    if [[ -d "$app" ]]; then
        pluginkit -r "$app/Contents/PlugIns/CopyPathExtension.appex" 2>/dev/null || true
    fi
    pkill -x CopyPathExtension 2>/dev/null || true

    mkdir -p "$HOME/Applications"
    rm -rf "$app"
    cp -R "$bundle" "$app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
    pluginkit -a "$app/Contents/PlugIns/CopyPathExtension.appex"
    pluginkit -e use -i "$ext_id"
    echo "Installed $app and enabled $ext_id"
}

case $TARGET in
    clip) build_clip ;;
    finder) build_finder ;;
    all) build_clip; build_finder ;;
esac
