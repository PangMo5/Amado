.PHONY: install generate build build-ios run test format format-check clean bootstrap

install:
	mise exec -- tuist install --force-resolved-versions

generate:
	mise exec -- tuist generate --no-open

# `tuist build` is deprecated; generate first, then drive the generated project
# through the `tuist xcodebuild` wrapper.
# -allowProvisioningUpdates lets xcodebuild register the iCloud container and
# Push Notifications capability with the signed-in Apple ID on first build.
build: generate
	mise exec -- tuist xcodebuild build -scheme Amado -workspace Amado.xcworkspace -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates

build-ios: generate
	mise exec -- tuist xcodebuild build -scheme AmadoiOS -workspace Amado.xcworkspace -configuration Debug -destination 'generic/platform=iOS Simulator' -allowProvisioningUpdates

# Build and launch the distinct Debug app so its local-network and Bluetooth
# privacy grants never collide with an installed release.
run: generate
	-killall Amado 2>/dev/null
	mise exec -- tuist xcodebuild build -scheme Amado -workspace Amado.xcworkspace -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData -allowProvisioningUpdates
	open DerivedData/Build/Products/Debug/Amado.app

test: generate
	mise exec -- tuist xcodebuild test -workspace Amado.xcworkspace -scheme Amado -configuration Debug -destination 'platform=macOS'

format:
	mise exec -- swiftformat .

format-check:
	mise exec -- swiftformat --lint .

clean:
	mise exec -- tuist clean
	rm -rf Derived DerivedData

bootstrap: install generate
