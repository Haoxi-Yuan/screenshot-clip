#!/bin/zsh
# Removes Screenshot Clip (LaunchAgent + app) and the Copy Path Finder extension.
set -u
LABEL=com.haoxiyuan.screenshot-clip
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null
pkill -x ScreenshotClip 2>/dev/null
rm -f "${HOME:?}/Library/LaunchAgents/$LABEL.plist"
rm -rf "${HOME:?}/Applications/ScreenshotClip.app"

pluginkit -r "${HOME:?}/Applications/CopyPath.app/Contents/PlugIns/CopyPathExtension.appex" 2>/dev/null
pkill -x CopyPathExtension 2>/dev/null
rm -rf "${HOME:?}/Applications/CopyPath.app"
echo "Removed Screenshot Clip and Copy Path. The log ~/Library/Logs/ScreenshotClip.log is kept."
