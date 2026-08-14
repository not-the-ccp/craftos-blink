#!/bin/sh
set -eu
mkdir -p build/fixtures
cc -nostdlib -static -Wl,--build-id=none -o build/fixtures/hello tests/fixtures/hello.S

