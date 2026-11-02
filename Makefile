.PHONY: generate build build-mac build-for-testing build-for-testing-mac test test-mac lint fault-seam-policy-self-check hardware-inventory-self-check clean

REPOSITORY_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

IOS_SIM_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro

# Regenerate the Xcode project from project.yml (local/setup only).
generate:
	xcodegen generate

build:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlang \
	  -destination '$(IOS_SIM_DESTINATION)' \
	  build CODE_SIGNING_ALLOWED=NO

build-mac:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMac \
	  build CODE_SIGNING_ALLOWED=NO

# Hosted: launches the iOS app and test runners. Requires the reviewed #60
# isolation gate and separate execution authorization.
test:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangIsolatedTests \
	  -destination '$(IOS_SIM_DESTINATION)' \
	  test CODE_SIGNING_ALLOWED=NO

# Compile-only: builds the iOS app and both test targets without launching anything.
build-for-testing:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangIsolatedTests \
	  -destination 'generic/platform=iOS Simulator' \
	  build-for-testing CODE_SIGNING_ALLOWED=NO

# Compile-only: builds FluxKlangMac and FluxKlangMacTests without launching anything.
build-for-testing-mac:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMacIsolatedTests \
	  -destination 'platform=macOS' \
	  build-for-testing CODE_SIGNING_ALLOWED=NO

# Hosted: launches FluxKlangMac.app as the test host. Requires the reviewed #60
# isolation gate after startup hardware isolation (#51), plus separate execution authorization.
test-mac:
	xcodebuild -project FluxKlang.xcodeproj -scheme FluxKlangMacIsolatedTests \
	  -destination 'platform=macOS' \
	  test CODE_SIGNING_ALLOWED=NO

lint:
	cd "$(REPOSITORY_ROOT)" && swiftlint --strict

fault-seam-policy-self-check:
	cd "$(REPOSITORY_ROOT)" && python3 -B -m unittest discover -s scripts/test-seam-policy -p 'test_*.py'
	cd "$(REPOSITORY_ROOT)" && python3 scripts/test-seam-policy/check.py

# Defence-in-depth tripwire for the passive hardware inventory lister (#67); runs nothing on hardware.
# --require-symbols: fail if the lister cannot be compiled and symbol-checked (needs a Swift toolchain).
hardware-inventory-self-check:
	bash scripts/hardware-inventory/passive-inventory.sh --self-check --require-symbols

clean:
	rm -rf build DerivedData
