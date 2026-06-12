# The machine's default Swift toolchain is broken against the current SDK;
# pin the Xcode-bundled one (see SPEC.md §7, M0 findings).
export TOOLCHAINS := com.apple.dt.toolchain.XcodeDefault

APP_NAME := AeroSpacePreview
BUNDLE   := build/$(APP_NAME).app
BINARY   := .build/release/$(APP_NAME)

.PHONY: build bundle run dev clean

build:
	xcrun swift build -c release

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
