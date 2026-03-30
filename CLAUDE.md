# Mac AltTab — Claude Context

## Stack
- Go (`main.go`) — app logic, CGO bridge
- Objective-C (`*.m`) — macOS APIs (hotkeys, window list, UI, screenshots)
- CGO: `#cgo LDFLAGS` links Cocoa, Carbon, ApplicationServices, ScreenCaptureKit

## Key Files
- `main.go` — entry point, AppSwitcher struct, CGO exports
- `hotkey_manager.m` — Carbon hotkey, NSApp init, event loop
- `window_manager.m` — CGWindowList, AX titles, permission checks
- `ui_window.m` — switcher UI, screenshot capture/cache, launch-at-login

## Build & Deploy
- `bash dev-restart.sh` — build + kill + copy to /Applications + reset all permissions + relaunch
- Manual build: `unset CGO_CPPFLAGS CGO_CXXFLAGS CGO_LDFLAGS && go build -o mac-alttab .`
- Copy binary: `cp mac-alttab "/Applications/Mac AltTab.app/Contents/MacOS/mac-alttab"`

## Reset (testing)
- Full reset: `pkill -f mac-alttab; tccutil reset Accessibility com.local.mac-alttab; tccutil reset ScreenCapture com.local.mac-alttab; rm -rf ~/Library/Caches/mac-alttab; defaults delete com.local.mac-alttab; launchctl unload ~/Library/LaunchAgents/com.local.mac-alttab.plist 2>/dev/null; rm -f ~/Library/LaunchAgents/com.local.mac-alttab.plist`

## Key Gotchas
- Every recompile changes binary hash → macOS auto-revokes TCC permissions (Accessibility + ScreenCapture)
- `CGPreflightScreenCaptureAccess()` returns YES on macOS 15 Sequoia even after `tccutil reset` (system auto-grants "limited" access)
- `NSAlert` and Carbon hotkeys must run on main thread with active NSRunLoop — use `dispatch_async(dispatch_get_main_queue(), ...)` from `onAppReady`
- `promptLaunchAtLogin` checks LaunchAgent plist existence at `~/Library/LaunchAgents/com.local.mac-alttab.plist`

## Permission Flow (ensurePermissionsGranted)
1. Accessibility first (required) — if missing, alert + open System Settings + `return`
2. Screen Recording second — if missing, alert + open System Settings
- Both checked on every launch until granted

## DMG Packaging
- `mkdir -p dmg_staging && cp -R "/Applications/Mac AltTab.app" dmg_staging/ && ln -sf /Applications dmg_staging/Applications && hdiutil create -volname "Mac AltTab" -srcfolder dmg_staging -ov -format UDZO -o "Mac AltTab.dmg" && rm -rf dmg_staging`

## Bundle
- App: `/Applications/Mac AltTab.app`
- Bundle ID: `com.local.mac-alttab`
- Binary: `Contents/MacOS/mac-alttab`
- Icon: `Contents/Resources/AppIcon.icns`
