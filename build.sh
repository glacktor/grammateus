#!/bin/zsh
# Сборка Grammateus.app (универсальная: Apple Silicon + Intel).
#   ./build.sh            — собрать в build/
#   ./build.sh --install  — собрать, положить в ~/Applications и запустить
#   ./build.sh --zip      — собрать и упаковать build/Grammateus.zip для раздачи
set -e
cd "$(dirname "$0")"

NAME=Grammateus
APP=build/$NAME.app
rm -rf build
mkdir -p $APP/Contents/MacOS

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13 main.swift -o build/$NAME-$arch \
    -framework Cocoa -framework Carbon -framework ServiceManagement
done
lipo -create build/$NAME-arm64 build/$NAME-x86_64 -output $APP/Contents/MacOS/$NAME
rm build/$NAME-arm64 build/$NAME-x86_64

cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.grammateus</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - $APP
echo "Собрано: $PWD/$APP"

if [[ "$1" == "--install" ]]; then
  pkill -x $NAME 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/$NAME.app
  cp -R $APP ~/Applications/
  open ~/Applications/$NAME.app
  echo "Установлено и запущено: ~/Applications/$NAME.app"
fi

if [[ "$1" == "--zip" ]]; then
  ditto -c -k --keepParent $APP build/$NAME.zip
  echo "Архив: $PWD/build/$NAME.zip"
fi
