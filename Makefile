.PHONY: generate build build-mac test lint clean

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

lint:
	swiftlint --strict

clean:
	rm -rf build DerivedData
