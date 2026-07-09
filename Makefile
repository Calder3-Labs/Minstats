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

# Universal (arm64 + x86_64) build; SwiftPM's --arch needs full Xcode,
# so build each slice via --triple and lipo them together.
universal:
	swift build -c release --triple arm64-apple-macosx14.0
	swift build -c release --triple x86_64-apple-macosx14.0

dmg: universal
	rm -rf $(BUNDLE) dist/dmg dist/$(APP).dmg
	mkdir -p $(BUNDLE)/Contents/MacOS dist/dmg
	lipo -create .build/arm64-apple-macosx/release/$(APP) \
		.build/x86_64-apple-macosx/release/$(APP) \
		-output $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	codesign --force --sign - $(BUNDLE)
	cp -R $(BUNDLE) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname $(APP) -srcfolder dist/dmg -ov -format UDZO dist/$(APP).dmg
	rm -rf dist/dmg

clean:
	rm -rf .build dist

.PHONY: build bundle run print universal dmg clean
