.PHONY: install generate build build-ios run test format clean bootstrap

install:
	tuist install

generate:
	tuist generate --no-open

# `tuist build` is deprecated; generate first, then drive the generated project
# through the `tuist xcodebuild` wrapper.
# -allowProvisioningUpdates lets xcodebuild register the iCloud container and
# Push Notifications capability with the signed-in Apple ID on first build.
build: generate
	tuist xcodebuild build -scheme Amado -workspace Amado.xcworkspace -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates

build-ios: generate
	tuist xcodebuild build -scheme AmadoiOS -workspace Amado.xcworkspace -configuration Debug -destination 'generic/platform=iOS Simulator' -allowProvisioningUpdates

# Build and launch the distinct Debug app so its local-network and Bluetooth
# privacy grants never collide with an installed release.
run: generate
	-killall Amado 2>/dev/null
	tuist xcodebuild build -scheme Amado -workspace Amado.xcworkspace -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData -allowProvisioningUpdates
	open DerivedData/Build/Products/Debug/Amado.app

test: generate
	tuist xcodebuild test -workspace Amado.xcworkspace -scheme Amado -configuration Debug -destination 'platform=macOS'

format:
	swiftformat .

clean:
	tuist clean
	rm -rf Derived DerivedData

bootstrap: install generate
