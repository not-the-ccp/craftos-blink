#!/bin/sh
set -eu

if ! command -v apt-get >/dev/null 2>&1; then
  echo "bootstrap-host: apt-get is required on the supported test host" >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y autoconf automake build-essential bzip2 ca-certificates curl \
  file git lua5.2 musl-tools pkg-config strace xz-utils

git submodule update --init --recursive
