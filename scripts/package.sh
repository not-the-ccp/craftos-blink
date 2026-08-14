#!/bin/sh
set -eu

version=${VERSION:-0.1.0-alpha.2}
name=craftos-blink-$version
stage=build/package/$name

rm -rf build/package dist
mkdir -p "$stage/LICENSES" dist
lua5.2 tools/generate-compatibility.lua .
lua5.2 tools/bundle.lua . dist/craftos_blink.lua api
lua5.2 tools/bundle.lua . dist/craftos-blink.lua cli
cp README.md LICENSE NOTICE "$stage/"
cp install.lua "$stage/"
cp LICENSES/Blink-ISC.txt "$stage/LICENSES/"
cp docs/compatibility.md generated/compatibility.json "$stage/"
cp dist/craftos_blink.lua dist/craftos-blink.lua "$stage/"
tar -C build/package -cJf "dist/$name.tar.xz" "$name"
cp install.lua dist/install.lua
(cd dist && sha256sum craftos_blink.lua craftos-blink.lua install.lua "$name.tar.xz" > SHA256SUMS)
