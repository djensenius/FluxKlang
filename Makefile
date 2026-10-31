.PHONY: generate build build-mac build-for-testing-mac test test-mac lint hardware-inventory-self-check clean

# Regenerate the Xcode project from project.yml (local/setup only).
generate:
	xcodegen generate

build:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlang \
	  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
	  build CODE_SIGNING_ALLOWED=NO

build-mac:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMac \
	  build CODE_SIGNING_ALLOWED=NO

test:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlang \
	  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
	  test CODE_SIGNING_ALLOWED=NO

# Compile-only: builds FluxKlangMac and FluxKlangMacTests without launching anything.
build-for-testing-mac:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMac \
	  -destination 'platform=macOS' \
	  build-for-testing CODE_SIGNING_ALLOWED=NO

# Hosted: launches FluxKlangMac.app as the test host. Do not run until hosted
# Mac execution is qualified by #60 after startup hardware isolation (#51).
test-mac:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMac \
	  -destination 'platform=macOS' \
	  test CODE_SIGNING_ALLOWED=NO

lint:
	swiftlint --strict

# Defence-in-depth tripwire for the passive hardware inventory lister (#67); runs nothing on hardware.
hardware-inventory-self-check:
	bash scripts/hardware-inventory/passive-inventory.sh --self-check

clean:
	rm -rf build DerivedData
