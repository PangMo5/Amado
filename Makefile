.PHONY: install generate generate-check build build-ios build-watch run test test-package format format-check clean bootstrap

XCODEBUILD = mise exec -- xcodebuild
SWIFT = mise exec -- swift
XCODE_FLAGS = -workspace Amado.xcworkspace -derivedDataPath DerivedData -clonedSourcePackagesDirPath .build/SourcePackages -onlyUsePackageVersionsFromResolvedFile -skipMacroValidation

install:
	$(XCODEBUILD) -resolvePackageDependencies $(XCODE_FLAGS) -scheme Amado

generate:
	$(SWIFT) run --package-path Tools/ProjectGenerator --disable-automatic-resolution generate-project

generate-check:
	$(SWIFT) run --package-path Tools/ProjectGenerator --disable-automatic-resolution generate-project --check

# Source folders synchronize automatically; regenerate only after changing the
# project generator. Open the workspace to develop apps and the local package.
build:
	$(XCODEBUILD) build $(XCODE_FLAGS) -scheme Amado -configuration Debug -destination 'platform=macOS' -allowProvisioningUpdates

build-ios:
	$(XCODEBUILD) build $(XCODE_FLAGS) -scheme AmadoiOS -configuration Debug -destination 'generic/platform=iOS Simulator' -allowProvisioningUpdates

build-watch:
	$(XCODEBUILD) build $(XCODE_FLAGS) -scheme AmadoWatch -configuration Debug -destination 'generic/platform=watchOS Simulator' -allowProvisioningUpdates

# Build and launch the distinct Debug app so its local-network and Bluetooth
# privacy grants never collide with an installed release.
run: build
	-killall Amado 2>/dev/null
	open DerivedData/Build/Products/Debug/Amado.app

test: test-package
	$(XCODEBUILD) test $(XCODE_FLAGS) -scheme Amado -configuration Debug -destination 'platform=macOS'

test-package:
	$(SWIFT) test --package-path AmadoPackage

format:
	mise exec -- swiftformat .

format-check:
	mise exec -- swiftformat --lint .

clean:
	$(XCODEBUILD) clean $(XCODE_FLAGS) -scheme Amado
	$(SWIFT) package --package-path AmadoPackage clean
	$(SWIFT) package --package-path Tools/ProjectGenerator clean

bootstrap: install
