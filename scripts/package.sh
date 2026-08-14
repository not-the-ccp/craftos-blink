#!/bin/sh
set -eu

version=${VERSION:-0.1.0-alpha.4}
name=craftos-blink-$version
stage=build/package/$name

rm -rf build/package dist
mkdir -p "$stage/LICENSES" "$stage/root/bin" dist
lua5.2 tools/generate-compatibility.lua .
lua5.2 tools/bundle.lua . dist/craftos_blink.lua api
lua5.2 tools/bundle.lua . dist/craftos-blink.lua cli
cp README.md LICENSE NOTICE "$stage/"
cp install.lua "$stage/"
cp LICENSES/Blink-ISC.txt "$stage/LICENSES/"
cp docs/compatibility.md generated/compatibility.json "$stage/"
cp dist/craftos_blink.lua dist/craftos-blink.lua "$stage/"
cp build/fixtures/minish "$stage/root/bin/minish"
cp build/fixtures/minish dist/craftos-blink-minish.elf
tar -C build/package -cJf "dist/$name.tar.xz" "$name"
cp install.lua dist/install.lua
(cd dist && sha256sum craftos_blink.lua craftos-blink.lua craftos-blink-minish.elf install.lua "$name.tar.xz" > SHA256SUMS)
