APP    := MinStats
BUNDLE := dist/$(APP).app
BIN    := .build/release/$(APP)
# The one version truth is agentVersion in the source; the bundle's
# Info.plist is stamped from it so Finder's Get Info can never drift
# from what the menu and /health report.
VERSION := $(shell sed -n 's/.*agentVersion = "\(.*\)"/\1/p' Sources/MinStats/Agent/StatsServer.swift)
# Developer ID for ALL builds, dev included, on purpose: the stable code
# identity is what lets the TLS key's Keychain approval stick across rebuilds
# (ad-hoc signing changed the cdhash every build → a password prompt per
# handshake) and stops local-network TCC re-prompts. Hardened runtime
# (--options runtime) is required for notarization.
SIGN := Developer ID Application: Erick Calderon (X5UDV422D8)

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(BUNDLE)/Contents/Info.plist
	cp Support/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --options runtime --sign "$(SIGN)" $(BUNDLE)

# Install to /Applications and launch THAT copy: SMAppService's login item
# resolves to /Applications/MinStats.app, so leaving a stale bundle there
# means every reboot silently regresses to it while dist/ runs the new code.
run: bundle
	pkill -x $(APP) || true
	rm -rf /Applications/$(APP).app
	cp -R $(BUNDLE) /Applications/$(APP).app
	open /Applications/$(APP).app

print:
	swift run $(APP) --print

# Run the agent headless (no menu bar UI), printing the pairing link. Lets the
# whole wire API be exercised with curl before Xcode is even involved.
serve:
	swift run $(APP) --serve

# Render the app icon (steel hex nut) into an .iconset and pack it with
# iconutil. No Xcode needed. AppIcon.icns is committed, so this only needs
# re-running when the artwork in GenerateIcon.swift changes.
icon:
	rm -rf Support/AppIcon.iconset
	swift Support/AppIcon/GenerateIcon.swift Support/AppIcon.iconset
	iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns
	rm -rf Support/AppIcon.iconset

# Universal (arm64 + x86_64) build; SwiftPM's --arch needs full Xcode,
# so build each slice via --triple and lipo them together.
universal:
	swift build -c release --triple arm64-apple-macosx14.0
	swift build -c release --triple x86_64-apple-macosx14.0

dmg: universal
	rm -rf $(BUNDLE) dist/dmg dist/$(APP).dmg
	mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources dist/dmg
	lipo -create .build/arm64-apple-macosx/release/$(APP) \
		.build/x86_64-apple-macosx/release/$(APP) \
		-output $(BUNDLE)/Contents/MacOS/$(APP)
	cp Support/Info.plist $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(BUNDLE)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(BUNDLE)/Contents/Info.plist
	cp Support/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	codesign --force --options runtime --timestamp --sign "$(SIGN)" $(BUNDLE)
	cp -R $(BUNDLE) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname $(APP) -srcfolder dist/dmg -ov -format UDZO dist/$(APP).dmg
	rm -rf dist/dmg

clean:
	rm -rf .build dist

.PHONY: build bundle run print serve icon universal dmg clean
