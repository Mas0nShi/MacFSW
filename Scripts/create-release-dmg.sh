#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  cat >&2 <<'EOF'
Usage:
  Scripts/create-release-dmg.sh /path/to/MacFSW.app /path/to/MacFSW-version.dmg
EOF
  exit 64
fi

APP_PATH="$1"
DMG_PATH="$2"
APP_NAME="$(basename "$APP_PATH")"
VOLUME_NAME="${DMG_VOLUME_NAME:-MacFSW}"
WINDOW_WIDTH="${DMG_WINDOW_WIDTH:-760}"
WINDOW_HEIGHT="${DMG_WINDOW_HEIGHT:-420}"
ICON_SIZE="${DMG_ICON_SIZE:-104}"
APP_ICON_X="${DMG_APP_ICON_X:-190}"
APP_ICON_Y="${DMG_APP_ICON_Y:-232}"
APPLICATIONS_ICON_X="${DMG_APPLICATIONS_ICON_X:-570}"
APPLICATIONS_ICON_Y="${DMG_APPLICATIONS_ICON_Y:-232}"

if [[ ! -d "$APP_PATH" || "$APP_NAME" != *.app ]]; then
  echo "Expected a .app bundle path, got: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

WORK_DIR="$(mktemp -d)"
MOUNT_PATH=""

cleanup() {
  if [[ -n "$MOUNT_PATH" && -d "$MOUNT_PATH" ]]; then
    hdiutil detach "$MOUNT_PATH" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

STAGING_DIR="$WORK_DIR/staging"
BACKGROUND_DIR="$STAGING_DIR/.background"
BACKGROUND_PATH="$BACKGROUND_DIR/background.png"
RW_DMG="$WORK_DIR/$VOLUME_NAME.rw.dmg"

mkdir -p "$BACKGROUND_DIR"
ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

swift - "$BACKGROUND_PATH" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" "$APP_ICON_X" "$APP_ICON_Y" "$APPLICATIONS_ICON_X" "$APPLICATIONS_ICON_Y" <<'SWIFT'
import AppKit
import Foundation

let arguments = CommandLine.arguments
let outputPath = arguments[1]
let width = CGFloat(Double(arguments[2])!)
let height = CGFloat(Double(arguments[3])!)
let appX = CGFloat(Double(arguments[4])!)
let appY = CGFloat(Double(arguments[5])!)
let applicationsX = CGFloat(Double(arguments[6])!)
let applicationsY = CGFloat(Double(arguments[7])!)

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

NSColor(calibratedRed: 0.965, green: 0.975, blue: 0.982, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()

let accent = NSColor(calibratedRed: 0.047, green: 0.373, blue: 0.635, alpha: 1)
let muted = NSColor(calibratedRed: 0.300, green: 0.337, blue: 0.380, alpha: 1)
let lightStroke = NSColor(calibratedRed: 0.790, green: 0.850, blue: 0.890, alpha: 1)

let titleStyle = NSMutableParagraphStyle()
titleStyle.alignment = .center

let titleAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
  .foregroundColor: NSColor(calibratedRed: 0.090, green: 0.110, blue: 0.135, alpha: 1),
  .paragraphStyle: titleStyle
]

let subtitleAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 14, weight: .regular),
  .foregroundColor: muted,
  .paragraphStyle: titleStyle
]

let requiredAttributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 13, weight: .medium),
  .foregroundColor: NSColor(calibratedRed: 0.210, green: 0.250, blue: 0.290, alpha: 1),
  .paragraphStyle: titleStyle
]

("Install MacFSW" as NSString).draw(
  in: NSRect(x: 0, y: height - 74, width: width, height: 34),
  withAttributes: titleAttributes
)

("Drag MacFSW.app to Applications before opening it." as NSString).draw(
  in: NSRect(x: 0, y: height - 103, width: width, height: 22),
  withAttributes: subtitleAttributes
)

("Required for System Extension approval and live capture." as NSString).draw(
  in: NSRect(x: 0, y: 42, width: width, height: 20),
  withAttributes: requiredAttributes
)

let appPoint = NSPoint(x: appX + 76, y: height - appY)
let applicationsPoint = NSPoint(x: applicationsX - 76, y: height - applicationsY)

let arrow = NSBezierPath()
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.move(to: appPoint)
arrow.line(to: applicationsPoint)
accent.setStroke()
arrow.stroke()

let arrowHead = NSBezierPath()
arrowHead.move(to: applicationsPoint)
arrowHead.line(to: NSPoint(x: applicationsPoint.x - 20, y: applicationsPoint.y + 14))
arrowHead.move(to: applicationsPoint)
arrowHead.line(to: NSPoint(x: applicationsPoint.x - 20, y: applicationsPoint.y - 14))
arrowHead.lineWidth = 6
arrowHead.lineCapStyle = .round
accent.setStroke()
arrowHead.stroke()

let sourceRing = NSBezierPath(ovalIn: NSRect(x: appX - 72, y: height - appY - 72, width: 144, height: 144))
sourceRing.lineWidth = 2
lightStroke.setStroke()
sourceRing.stroke()

let targetRing = NSBezierPath(ovalIn: NSRect(x: applicationsX - 72, y: height - applicationsY - 72, width: 144, height: 144))
targetRing.lineWidth = 2
lightStroke.setStroke()
targetRing.stroke()

image.unlockFocus()

guard
  let tiff = image.tiffRepresentation,
  let bitmap = NSBitmapImageRep(data: tiff),
  let png = bitmap.representation(using: .png, properties: [:])
else {
  fputs("Failed to render DMG background.\n", stderr)
  exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
SWIFT

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen)"
MOUNT_PATH="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '$0 ~ /\/Volumes\// { print $NF; exit }')"

if [[ -z "$MOUNT_PATH" || ! -d "$MOUNT_PATH" ]]; then
  echo "Failed to mount temporary DMG." >&2
  echo "$ATTACH_OUTPUT" >&2
  exit 1
fi

/usr/bin/SetFile -a V "$MOUNT_PATH/.background" || true

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 120 + $WINDOW_WIDTH, 120 + $WINDOW_HEIGHT}
    set theViewOptions to icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to $ICON_SIZE
    set background picture of theViewOptions to file ".background:background.png"
    set position of item "$APP_NAME" of container window to {$APP_ICON_X, $APP_ICON_Y}
    set position of item "Applications" of container window to {$APPLICATIONS_ICON_X, $APPLICATIONS_ICON_Y}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_PATH" -quiet
MOUNT_PATH=""

hdiutil convert "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

echo "$DMG_PATH"
