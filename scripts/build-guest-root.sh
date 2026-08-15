#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache_dir=${CRAFTOS_BLINK_CACHE:-"$project_dir/.cache/guest-toolchain"}
output_dir=${1:-"$project_dir/build/guest-root"}
export KCONFIG_NOTIMESTAMP=1
export LC_ALL=C
export TZ=UTC

dash_version=0.5.12
dash_archive="dash-$dash_version.tar.gz"
dash_url="https://git.kernel.org/pub/scm/utils/dash/dash.git/snapshot/$dash_archive"
dash_sha256=0d632f6b945058d84809cac7805326775bd60cb4a316907d0bd4228ff7107154

busybox_version=1.37.0
busybox_archive="busybox-$busybox_version.tar.bz2"
busybox_url="https://busybox.net/downloads/$busybox_archive"
busybox_sha256=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4

need_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "build-guest-root: missing required command: $1" >&2
    exit 1
  }
}

fetch_verified() {
  url=$1
  destination=$2
  checksum=$3
  if [ ! -f "$destination" ]; then curl -fL --retry 3 -o "$destination" "$url"; fi
  printf '%s  %s\n' "$checksum" "$destination" | sha256sum -c - >/dev/null
}

for command_name in autoconf automake curl make musl-gcc sha256sum tar; do
  need_command "$command_name"
done

mkdir -p "$cache_dir" "$output_dir/bin" "$output_dir/tmp"

fetch_verified "$dash_url" "$cache_dir/$dash_archive" "$dash_sha256"
if [ ! -d "$cache_dir/dash-$dash_version" ]; then
  tar -xzf "$cache_dir/$dash_archive" -C "$cache_dir"
fi
dash_source="$cache_dir/dash-$dash_version"
if [ ! -x "$dash_source/configure" ]; then (cd "$dash_source" && ./autogen.sh); fi
(cd "$dash_source" && \
  CC=musl-gcc CFLAGS='-Os -fno-stack-protector' LDFLAGS='-static' \
    ./configure --enable-static --disable-lineno >/dev/null && \
  make -j2 >/dev/null)
cp "$dash_source/src/dash" "$output_dir/bin/dash"
strip "$output_dir/bin/dash"

fetch_verified "$busybox_url" "$cache_dir/$busybox_archive" "$busybox_sha256"
if [ ! -d "$cache_dir/busybox-$busybox_version" ]; then
  tar -xjf "$cache_dir/$busybox_archive" -C "$cache_dir"
fi
busybox_source="$cache_dir/busybox-$busybox_version"
(cd "$busybox_source" && make distclean >/dev/null 2>&1 || true)
(cd "$busybox_source" && make allnoconfig >/dev/null)
while IFS= read -r option_name; do
  case "$option_name" in ''|'#'*) continue ;; esac
  sed -i "s/^# CONFIG_${option_name} is not set$/CONFIG_${option_name}=y/" \
    "$busybox_source/.config"
done < "$project_dir/config/busybox-minimal.config"
(cd "$busybox_source" && yes '' | make oldconfig >/dev/null && \
  make -j2 CC=musl-gcc busybox >/dev/null)
cp "$busybox_source/busybox" "$output_dir/bin/busybox"

# ComputerCraft filesystems have no symlinks. Use ordinary copies so PATH
# lookup behaves the same on the host, CraftOS-PC, and in-game storage.
cp "$output_dir/bin/dash" "$output_dir/bin/sh"
while IFS= read -r applet_name; do
  case "$applet_name" in ''|'#'*) continue ;; esac
  cp "$output_dir/bin/busybox" "$output_dir/bin/$applet_name"
done < "$project_dir/config/busybox-applets.list"

{
  printf 'dash_version=%s\n' "$dash_version"
  printf 'dash_source_sha256=%s\n' "$dash_sha256"
  printf 'dash_binary_sha256='
  sha256sum "$output_dir/bin/dash" | awk '{print $1}'
  printf 'busybox_version=%s\n' "$busybox_version"
  printf 'busybox_source_sha256=%s\n' "$busybox_sha256"
  printf 'busybox_binary_sha256='
  sha256sum "$output_dir/bin/busybox" | awk '{print $1}'
  printf 'busybox_applets='
  tr '\n' ' ' < "$project_dir/config/busybox-applets.list" | sed 's/[[:space:]]*$//'
  printf '\n'
} > "$output_dir/BUILD-MANIFEST"

echo "build-guest-root: created $output_dir"
