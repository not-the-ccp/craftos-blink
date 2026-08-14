.PHONY: all check check-upstream bootstrap craftos-pc clean

LUA ?= lua5.2

all:
	@echo "CraftOS Blink is a Lua project; run 'make check'."

bootstrap:
	./scripts/bootstrap-host.sh

craftos-pc:
	./scripts/bootstrap-craftos-pc.sh

check-upstream:
	./scripts/check-upstream.sh

check:
	./tests/build-fixtures.sh
	$(LUA) tests/run.lua

clean:
	rm -rf build dist
