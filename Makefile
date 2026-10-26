# GhosttyKit (libghostty) is built from the pinned vendor/ghostty submodule.
# The Xcode project is generated from project.yml with XcodeGen.

DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Codecave.app
GHOSTTYKIT := vendor/ghostty/macos/GhosttyKit.xcframework

.PHONY: all ghostty project app run clean

all: app

$(GHOSTTYKIT):
	./scripts/build-ghosttykit.sh

ghostty:
	./scripts/build-ghosttykit.sh

project: Codecave.xcodeproj

Codecave.xcodeproj: project.yml
	xcodegen generate --quiet

app: $(GHOSTTYKIT) project
	xcodebuild -project Codecave.xcodeproj -scheme Codecave -configuration Debug \
		-derivedDataPath $(DERIVED) -quiet build

run: app
	open $(APP)

clean:
	rm -rf $(DERIVED) Codecave.xcodeproj
