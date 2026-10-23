CONFIG ?= Debug
APP = build/Build/Products/$(CONFIG)/Tern.app

.PHONY: project build run release clean smoke bench

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Tern.xcodeproj -scheme Tern -configuration $(CONFIG) -destination "platform=macOS,arch=arm64" -derivedDataPath build -quiet build

run: build
	open $(APP)

release:
	$(MAKE) build CONFIG=Release

clean:
	rm -rf build Tern.xcodeproj

# End-to-end smoke test: real windows, tabs, suspension and an unpacked MV3 extension.
smoke: build
	@mkdir -p build/smoke
	@python3 -m http.server 8765 --bind 127.0.0.1 --directory Tests/Smoke/site >/dev/null 2>&1 & echo $$! > build/smoke/server.pid
	@for i in $$(seq 100); do curl -sf -o /dev/null http://127.0.0.1:8765/one.html && break; sleep 0.1; done
	@TERN_SMOKE="$(CURDIR)/build/smoke" TERN_SOCKET=/tmp/tern-smoke-$$$$.sock TERN_SMOKE_BASE=http://localhost:8765 TERN_SMOKE_EXT="$(CURDIR)/Tests/Smoke/extension" \
		"$(APP)/Contents/MacOS/Tern"; status=$$?; kill `cat build/smoke/server.pid`; exit $$status

# Launch time, memory per tab, and palette and tab-switch latency, measured through the agent API.
# SAVE=1 keeps the results as the baseline later runs are compared against.
bench:
	$(MAKE) build CONFIG=Release
	@python3 Scripts/bench.py --app build/Build/Products/Release/Tern.app $(if $(SAVE),--save-baseline)
