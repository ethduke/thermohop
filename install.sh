#!/bin/sh
set -eu
# Install a CLI-only bundle with a stable privacy identity. No window or menu UI.
cd "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
swift build -c release
bundle="${THERMOHOP_INSTALL_DIR:-$HOME/Applications}/Thermohop.app"
bin_dir="${THERMOHOP_BIN_DIR:-$HOME/.local/bin}"
if [ -e "$bundle" ] && [ ! -f "$bundle/Contents/Resources/thermohop-install-marker" ]; then
    printf '%s\n' 'Refusing to overwrite a bundle not installed by Thermohop.' >&2
    exit 1
fi
if [ -e "$bin_dir/thermohop" ] || [ -L "$bin_dir/thermohop" ]; then
    if [ ! -L "$bin_dir/thermohop" ] || [ "$(readlink "$bin_dir/thermohop")" != "$bundle/Contents/MacOS/thermohop" ]; then
        printf '%s\n' 'Refusing to replace an existing unrelated thermohop executable.' >&2
        exit 1
    fi
fi
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources" "$bin_dir"
cp .build/release/thermohop "$bundle/Contents/MacOS/thermohop"
cp Info.plist "$bundle/Contents/Info.plist"
touch "$bundle/Contents/Resources/thermohop-install-marker"
codesign --force --sign - --identifier io.thermohop.cli "$bundle"
ln -sf "$bundle/Contents/MacOS/thermohop" "$bin_dir/thermohop"
printf '%s\n' "Installed CLI: $bin_dir/thermohop" 'Add that bin directory to PATH, then run thermohop wifi permission request for initial setup.'
