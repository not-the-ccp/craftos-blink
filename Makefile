.PHONY: all check check-craftos-pc check-differential check-guest-coverage check-guest-filesystem check-guest-processes check-guest-syscalls check-upstream compatibility guest-root package bootstrap craftos-pc clean

LUA ?= lua5.2

all:
	@echo "CraftOS Blink is a Lua project; run 'make check'."

bootstrap:
	./scripts/bootstrap-host.sh

craftos-pc:
	./scripts/bootstrap-craftos-pc.sh

check-upstream:
	./scripts/check-upstream.sh

check-craftos-pc:
	./scripts/check-craftos-pc.sh

check-differential:
	./tests/differential.sh

guest-root:
	./scripts/build-guest-root.sh

check-guest-coverage: guest-root
	./tools/check-guest-coverage.sh

check-guest-filesystem: guest-root
	./tests/guest-filesystem.sh

check-guest-processes: guest-root
	./tests/guest-process.sh

check-guest-syscalls: guest-root
	./tools/check-guest-syscalls.sh

check:
	./tests/build-fixtures.sh
	mkdir -p build
	$(LUA) tools/bundle.lua . build/test-craftos-blink.lua cli
	$(LUA) tests/run.lua
	$(LUA) tests/bundle-environment-test.lua

compatibility:
	$(LUA) tools/generate-compatibility.lua .

package: check compatibility
	./scripts/package.sh

clean:
	rm -rf build dist
