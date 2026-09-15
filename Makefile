.PHONY: gen build test run clean
gen:
	xcodegen generate
build: gen
	xcodebuild -project Ties.xcodeproj -scheme Ties -configuration Debug -derivedDataPath build/DerivedData build | tail -20
test:
	cd TiesCore && swift test
run: build
	open build/DerivedData/Build/Products/Debug/Ties.app
clean:
	rm -rf build Ties.xcodeproj TiesCore/.build
