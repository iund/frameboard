# Frameboard

Two native projects: `macOS/Frameboard.xcodeproj` and `Android/` (Java, Gradle, Android 16 / API 36).

The macOS camera is the source. An app selects **Frameboard Camera**, which starts with an unmodified webcam image. The Android tablet pairs by Bluetooth and then sends layout and drawing commands over the same LAN. The Mac composites the picture; the tablet is a controller, not the camera.

## Run the apps

Android is installed on the connected T50 tablet. See [Android build and controls](Android/README.md). The Mac preview app can run without virtual-camera signing using `./scripts/run-macos-preview.sh`; follow [macOS setup](macOS/SETUP.md) to enable the actual virtual camera.

## Current implementation and handoff

See [HANDOFF.md](HANDOFF.md) for build steps, device checks, integration status, and outstanding work. This repository is a development starter, not a signed installable driver. In particular, the App Group JPEG bridge and Bluetooth-to-LAN authentication need validation and hardening on macOS hardware.

## Wire protocol (v1)

The Mac advertises `_frameboard._tcp` on Bonjour. The Android app discovers it through `NsdManager`. Once connected, each side exchanges one UTF-8 JSON object per line. All coordinates are normalized to `[0,1]` in the 16:9 output, independently of tablet pixels.

Android → Mac: `{"type":"hello","token":"..."}`, `{"type":"layout","x":0.15,"y":0.15,"w":0.7,"h":0.7}`, `{"type":"stroke","points":[[0.1,0.2],[0.2,0.3]]}`, `{"type":"erase","x":0.1,"y":0.2,"radius":0.02}`, `{"type":"clear"}`.

Mac → Android: `{"type":"status","state":"connected"}`, `{"type":"preview","jpeg":"<base64 JPEG>"}`. A physical webcam feed is never sent to Bluetooth. Bluetooth is for discovery and the short pairing exchange; Wi-Fi carries commands and preview. Production transport needs authenticated encryption and replay protection before use on an untrusted LAN.

Preview JPEGs contain the entire composed 1280×720 output, including the webcam
rectangle and committed ink. Controllers display them over the complete 16:9
stage. The Mac sends previews only after accepting `hello`; Android enables
commands after receiving the connected status. Incoming Mac command buffering is
capped at 256 KiB; Android preview lines are capped at 2 MiB. These limits do not
replace authenticated encryption.

After accepting hello, the Mac also sends a `layout` object with the current `x`, `y`, `w`, and `h` so the controller can restore its camera selection rectangle.
