# GhosttyKit (libghostty) is built from the pinned vendor/ghostty submodule.
# The Xcode project is generated from project.yml with XcodeGen.

# Debug for development, Release for a build to actually use or ship.
# Override per invocation with `make app CONFIG=Release`, or use the
# `release` / `run-release` targets.
CONFIG ?= Debug

DERIVED := build
# Recursive so it picks up the configuration of the target being built.
APP = $(DERIVED)/Build/Products/$(CONFIG)/Hypertty.app
GHOSTTYKIT := vendor/ghostty/macos/GhosttyKit.xcframework

.PHONY: all ghostty project app release run run-release clean

all: app

$(GHOSTTYKIT):
	./scripts/build-ghosttykit.sh

ghostty:
	./scripts/build-ghosttykit.sh

# Always regenerated so new source files are picked up; the cache makes
# it a no-op when nothing changed.
project:
	xcodegen generate --quiet --use-cache

app: $(GHOSTTYKIT) project
	xcodebuild -project Hypertty.xcodeproj -scheme Hypertty -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) -quiet build

release: CONFIG := Release
release: app
	@echo "Built $(APP)"

run: app
	open $(APP)

run-release: CONFIG := Release
run-release: run

clean:
	rm -rf $(DERIVED) Hypertty.xcodeproj
