.PHONY: all check check-craftos-pc check-differential check-upstream compatibility package bootstrap craftos-pc clean

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
