# `make` runs each recipe line in its own shell, and a pipeline's exit status is its LAST
# command — so a bare `xcodebuild ... | tail -20` reports success on a failed build and CI
# goes green. `set -o pipefail` in the recipe makes the pipeline fail when xcodebuild does.
# (`.SHELLFLAGS` would be tidier, but macOS ships GNU Make 3.81, which ignores it.)
SHELL := /bin/bash

.PHONY: gen build test run clean
gen:
	xcodegen generate
build: gen
	set -o pipefail; xcodebuild -project Ties.xcodeproj -scheme Ties -configuration Debug -derivedDataPath build/DerivedData build | tail -20
test:
	cd TiesCore && swift test
run: build
	open build/DerivedData/Build/Products/Debug/Ties.app
clean:
	rm -rf build Ties.xcodeproj TiesCore/.build
