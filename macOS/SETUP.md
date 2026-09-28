# Run Frameboard on this Mac

Both the host app and camera extension compile with the installed Xcode 27.
No valid code-signing identities were found in the user's keychain, so the
virtual camera has not been activated or tested in Photo Booth.

## Try webcam capture and tablet control now

A locally signed preview build was launched from:

`build/macOS-preview/Build/Products/Debug/Frameboard.app`

Allow Camera, Bluetooth and Local Network access if macOS asks. Keep the app
running. The window should show your physical webcam and the current LAN port,
IPv4 addresses and session token. If Camera was denied, enable Frameboard under
System Settings → Privacy & Security → Camera, then quit and reopen it.

To rebuild and launch this mode from the repository root:

```sh
./scripts/run-macos-preview.sh
```

This build intentionally omits the distribution entitlements and skips camera
extension activation and the App Group frame bridge. It is a local development
preview, not an installable virtual camera. Do not distribute it as the full app.
Use the script rather than opening the bundle directly so the preview-only
argument is supplied.

On the tablet, tap **Connect → Manual LAN connection** and enter one of the Mac's
Wi-Fi addresses, the port and the complete session token shown in the Mac window.
Both devices must be on the same LAN. Do not enter `localhost` or `127.0.0.1` on
the tablet: that would address the tablet itself. The token and port can change
when the Mac app restarts. Bluetooth pairing is also available, but the initial
hardware attempt discovered the Mac and then timed out during pairing; the full
BLE-to-LAN flow remains unverified.

## Enable Frameboard Camera in video apps

1. Open `macOS/Frameboard.xcodeproj` in Xcode. In Xcode Settings → Accounts,
   sign in to your Apple development account and create/download an Apple
   Development signing certificate. Your team must support the required App
   Groups and System Extension capabilities.
2. Select the **project**, then Build Settings → All → User-Defined. Replace
   `FRAMEBOARD_BUNDLE_PREFIX` (`com.example.frameboard`) with an identifier you
   control. The host bundle ID follows this value and the camera extension adds
   `.cameraextension`; keep that relationship intact.
3. Set `FRAMEBOARD_APP_GROUP` to your team's shared App Group identifier. Its
   default is `group.$(FRAMEBOARD_BUNDLE_PREFIX)`. Register/select that same group
   for **both** targets under Signing & Capabilities. Both entitlements and both
   Info.plists already read this build setting. The extension's nested
   `CMIOExtension.CMIOExtensionMachServiceName` is derived from it too.
4. For **Frameboard** and **FrameboardCameraExtension**, choose the same Team and
   enable Automatically manage signing. Preserve App Sandbox and App Groups on
   both targets; preserve the host's System Extension install entitlement and
   camera, Bluetooth and network permissions. Resolve any provisioning errors
   Xcode reports before continuing.
5. Build the **Frameboard** scheme for **My Mac** with ordinary signing settings.
   Do not use the preview script or its signing overrides. Quit the preview app.
   In Xcode's Products group, reveal `Frameboard.app` in Finder, copy the signed
   app to `/Applications`, and open that copy.
6. Allow camera, Bluetooth and local-network access. Click **Install / update
   virtual camera** in Frameboard. Approve the extension in System Settings when
   prompted (on recent macOS: General → Login Items & Extensions → Camera
   Extensions). If macOS requests a restart, perform it and reopen Frameboard.
7. With the tablet disconnected, open Photo Booth → Camera → **Frameboard
   Camera**. Verify the physical webcam picture first. Then connect the tablet
   and try Blackboard, pen, eraser, Move & zoom and Full camera.

The host currently must stay running to supply frames. The extension holds the
last good frame when the JPEG bridge stops updating; before receiving its first
frame it produces black. Hardware activation, App Group sharing across the
extension's service account, frame orientation, and multiple camera clients
still need validation after signing is available.

Apple references: [Creating a camera extension](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o),
[Camera extensions walkthrough](https://developer.apple.com/videos/play/wwdc2022/10022/).
The installed Xcode camera-extension template was also used to check the
Info.plist structure and the provider/device/stream property declarations.
