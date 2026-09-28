#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xcodebuild -quiet -project "$project_root/macOS/Frameboard.xcodeproj" \
  -scheme Frameboard -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$project_root/build/macOS-preview" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_ENTITLEMENTS="$project_root/macOS/Frameboard/App/Preview.entitlements" CODE_SIGNING_REQUIRED=NO build
open "$project_root/build/macOS-preview/Build/Products/Debug/Frameboard.app" \
  --args -FrameboardPreviewOnly YES
