#!/bin/sh
set -eu

version=2.8.3
expected=f25536c7a05f67827fe44573ff65627cbe595e13c75815ef86a4e1f3bd33a88c
asset=CraftOS-PC.x86_64.AppImage
repo=MCJack123/craftos2
cache=.cache/craftos-pc

mkdir -p "$cache"
if [ ! -f "$cache/$asset" ]; then
  gh release download "v$version" --repo "$repo" --pattern "$asset" \
    --dir "$cache"
fi

actual=$(sha256sum "$cache/$asset" | awk '{print $1}')
if [ "$actual" != "$expected" ]; then
  echo "bootstrap-craftos-pc: checksum mismatch for $asset" >&2
  echo "expected $expected" >&2
  echo "actual   $actual" >&2
  exit 1
fi

chmod +x "$cache/$asset"
extract="$cache/appimage-root"
if [ ! -x "$extract/AppRun" ]; then
  oldpwd=$PWD
  cd "$cache"
  "./$asset" --appimage-extract >/dev/null
  rm -rf appimage-root
  mv squashfs-root appimage-root
  cd "$oldpwd"
fi

echo "$extract/AppRun"

