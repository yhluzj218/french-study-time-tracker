#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p build/FrenchStudyTimeTracker.app/Contents/MacOS build/module-cache
swiftc -module-cache-path build/module-cache -swift-version 5 -O Core.swift App.swift -o build/FrenchStudyTimeTracker.app/Contents/MacOS/FrenchStudyTimeTracker -framework AppKit -framework SwiftUI -framework ApplicationServices -framework Security
cp Info.plist build/FrenchStudyTimeTracker.app/Contents/Info.plist
codesign --force --sign - build/FrenchStudyTimeTracker.app
build/FrenchStudyTimeTracker.app/Contents/MacOS/FrenchStudyTimeTracker --self-test
