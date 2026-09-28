#!/bin/bash
# DynamicBar build script — no Xcode required, uses the Command Line Tools Swift toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="DynamicBar"
BUNDLE_ID="com.dynamicbar.DynamicBar"
VERSION="1.0.0"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
ARCHS="${ARCHS:-x86_64}"
DEPLOY_TARGET="${DEPLOY_TARGET:-13.0}"

echo "==> DynamicBar build"
echo "    root:    $ROOT"
echo "    archs:   $ARCHS"
echo "    target:  macOS $DEPLOY_TARGET"

# ---------------------------------------------------------------- toolchain --
if ! command -v swiftc >/dev/null 2>&1; then
  echo "ERROR: swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi
SDK="$(xcrun --show-sdk-path)"
echo "    sdk:     $SDK"

# ------------------------------------------------------------------- layout --
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/obj"

SOURCES=$(find "$ROOT/Sources" -name '*.swift' | sort)
SRC_COUNT=$(echo "$SOURCES" | wc -l | tr -d ' ')
echo "    sources: $SRC_COUNT swift files"

FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework Foundation -framework Combine -framework CoreGraphics -framework UniformTypeIdentifiers -framework CryptoKit)

# ------------------------------------------------------------------ compile --
BINARIES=()
for ARCH in $ARCHS; do
  echo "==> compiling + linking ($ARCH)"
  ARCH_BIN="$BUILD_DIR/obj/$APP_NAME.$ARCH"
  # Whole-module compilation in a single driver invocation: Swift needs all
  # sources together in one invocation to resolve cross-file symbols.
  # shellcheck disable=SC2086
  swiftc \
    -swift-version 5 \
    -O \
    -wmo \
    -parse-as-library \
    -module-name "$APP_NAME" \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -sdk "$SDK" \
    "${FRAMEWORKS[@]}" \
    -o "$ARCH_BIN" \
    $SOURCES
  BINARIES+=("$ARCH_BIN")
done

# --------------------------------------------------------- media helper dylib --
# A dylib the app loads into /usr/bin/perl. MediaRemote answers only trusted
# platform binaries, so the Now Playing calls have to happen inside perl's
# process — see Sources/DynamicBarMediaHelper/helper.m.
echo "==> building media helper dylib"
HELPER_SRC="$ROOT/Sources/DynamicBarMediaHelper/helper.m"
HELPER_OUT="$APP/Contents/Resources/libdynamicbarmedia.dylib"
for ARCH in $ARCHS; do
  clang \
    -dynamiclib \
    -fobjc-arc \
    -O2 \
    -arch "$ARCH" \
    -mmacosx-version-min="$DEPLOY_TARGET" \
    -isysroot "$SDK" \
    -framework Foundation \
    -install_name "@rpath/libdynamicbarmedia.dylib" \
    -o "$BUILD_DIR/obj/libdynamicbarmedia.$ARCH.dylib" \
    "$HELPER_SRC"
done
if [ "${#ARCHS}" -eq 1 ] || [ "$(echo "$ARCHS" | wc -w | tr -d ' ')" = "1" ]; then
  cp "$BUILD_DIR/obj/libdynamicbarmedia.$(echo "$ARCHS" | awk '{print $1}').dylib" "$HELPER_OUT"
else
  lipo -create -output "$HELPER_OUT" $(for ARCH in $ARCHS; do echo "$BUILD_DIR/obj/libdynamicbarmedia.$ARCH.dylib"; done)
fi
codesign --force --sign - --timestamp=none "$HELPER_OUT" >/dev/null 2>&1 || true
echo "    helper:  $(basename "$HELPER_OUT") ($(lipo -archs "$HELPER_OUT" 2>/dev/null || echo '?'))"

# --------------------------------------------------------------------- lipo --
if [ "${#BINARIES[@]}" -eq 1 ]; then
  cp "${BINARIES[0]}" "$APP/Contents/MacOS/$APP_NAME"
else
  lipo -create -output "$APP/Contents/MacOS/$APP_NAME" "${BINARIES[@]}"
fi
chmod +x "$APP/Contents/MacOS/$APP_NAME"

# --------------------------------------------------------------------- plist --
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --------------------------------------------------------------------- icon --
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# ----------------------------------------------------------------- code sign --
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
  && echo "    ad-hoc signed" \
  || echo "    (ad-hoc codesign failed — app still runs)"

echo "==> built: $APP"
file "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    /'
echo "==> done"
