.PHONY: generate build build-mac build-for-testing-mac test test-mac lint clean

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

clean:
	rm -rf build DerivedData
