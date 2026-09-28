# Frameboard for Android

The controller targets Android 16 / API 36 and supports API 31+. It is Java,
Android Gradle Plugin 8.13.0, Gradle 8.13 and JDK 17. No Android Studio is needed
to build with the included wrapper and an installed Android SDK.

From this directory, on this Mac:

```sh
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./gradlew :app:assembleDebug :app:lintDebug
/Users/iu/Library/Android/sdk/platform-tools/adb -s T50EEA000024871 install -r app/build/outputs/apk/debug/app-debug.apk
/Users/iu/Library/Android/sdk/platform-tools/adb -s T50EEA000024871 shell am start -W -n com.frameboard.controller/.MainActivity
```

On a different development machine, set `sdk.dir` in local.properties (not
version controlled) or set ANDROID_HOME, install API 36, and substitute its adb
path and the device's serial.

- **Practice** lets you try the blackboard without a Mac and never sends commands.
- **Connect** offers Bluetooth pairing, Manual LAN and Disconnect. Pairing can
  be retried without restarting the app. Manual LAN needs the Mac's address,
  current listener port and session token shown in its window.
- **Blackboard** reduces the webcam to the upper-right corner and selects pen.
- **Move & zoom** drags/pinches the camera; **Full camera** restores its layout.
- **White pen** draws around the camera; **Eraser** removes touched strokes;
  **Clear ink** asks before clearing all notes.

Successful build/lint, installation, cold start and local drawing/eraser/layout
were verified on the connected T50. BLE pairing discovered the Mac but timed out;
live LAN preview/control and multitouch still require hardware validation.

Compatibility reference: [AGP 8.13 build requirements](https://developer.android.com/build/releases/agp-8-13-0-release-notes).
