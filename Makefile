APP    := StatsMenu
BUNDLE := dist/$(APP).app
BIN    := .build/release/$(APP)

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)

run: bundle
	pkill -x $(APP) || true
	open $(BUNDLE)

print:
	swift run $(APP) --print

clean:
	rm -rf .build dist

.PHONY: build bundle run print clean
