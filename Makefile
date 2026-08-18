# Custom Swift toolchains can be incompatible with the installed macOS SDK;
# pin the Xcode-bundled toolchain for reproducible builds.
export TOOLCHAINS := com.apple.dt.toolchain.XcodeDefault

APP_NAME := AeroSpacePreview
BUNDLE   := build/$(APP_NAME).app
BINARY   := .build/release/$(APP_NAME)

.PHONY: build bundle run dev test clean

build:
	xcrun swift build -c release

test:
	xcrun swift test

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(BUNDLE)/Contents/MacOS
	cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	cp $(BINARY) $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	codesign --force --sign - $(BUNDLE)

# Launch as a regular app (detached).
run: bundle
	open $(BUNDLE)

# Run the bundled binary attached to the terminal, so NSLog output is visible.
dev: bundle
	$(BUNDLE)/Contents/MacOS/$(APP_NAME)

clean:
	rm -rf .build build
