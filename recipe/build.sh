#!/usr/bin/env bash
set -euo pipefail
root=$SRC_DIR
# rattler-build's own path-source copy fails here, so copy the tree by hand.
tar -C "$RECIPE_DIR/.." --exclude=./.pixi --exclude=./.git --exclude=./build --exclude=./.dart_tool \
  --exclude=./output --exclude=./linux/flutter/ephemeral -cf - . | tar -C "$root" -xf -
cd "$root"
id=dev.codegod.pixibrowse
bundle=$root/build/linux/x64/release/bundle

export HOME=$SRC_DIR/.home PUB_CACHE=$SRC_DIR/.pub-cache
export CC=$BUILD_PREFIX/bin/clang CXX=$BUILD_PREFIX/bin/clang++
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export CFLAGS="-I$PREFIX/include" CXXFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib -Wl,-rpath-link,$PREFIX/lib"
pkg-config --print-errors --exists gtk+-3.0 || { ls "$PREFIX/lib/pkgconfig" | head -50; exit 1; }
flutter config --no-analytics --no-cli-animations >/dev/null 2>&1 || true
flutter pub get
flutter build linux --release

mkdir -p "$PREFIX/lib/pixibrowse" "$PREFIX/bin"
cp -a "$bundle/." "$PREFIX/lib/pixibrowse/"
# Flutter (and the window icon lookup) resolve data/ relative to the real executable, so a symlink works.
ln -sf ../lib/pixibrowse/pixibrowse "$PREFIX/bin/pixibrowse"

install -Dm644 linux/$id.desktop "$PREFIX/share/applications/$id.desktop"
install -Dm644 linux/$id.svg "$PREFIX/share/icons/hicolor/scalable/apps/$id.svg"
install -Dm644 linux/runner/resources/pixibrowse.png "$PREFIX/share/icons/hicolor/256x256/apps/$id.png"

# menuinst: `pixi global install` reads Menu/*.json to add a desktop launcher with this icon.
install -Dm644 "$RECIPE_DIR/menu.json" "$PREFIX/Menu/pixibrowse.json"
install -Dm644 linux/runner/resources/pixibrowse.png "$PREFIX/Menu/pixibrowse.png"
