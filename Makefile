APP      := build/ClaudeUsage.app
BIN      := $(APP)/Contents/MacOS/ClaudeUsage
SOURCES  := Sources/UsageCore.swift Sources/App.swift Sources/main.swift
SWIFTC   := xcrun swiftc
FLAGS    := -O -swift-version 5
MIN_OS   := macos14.0

.PHONY: all run dump test screenshot clean

all: $(BIN)

# Universal binary: one slice per architecture, joined with lipo.
$(BIN): $(SOURCES) Resources/Info.plist
	mkdir -p $(APP)/Contents/MacOS build/arm64 build/x86_64
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	$(SWIFTC) $(FLAGS) -target arm64-apple-$(MIN_OS) $(SOURCES) -o build/arm64/ClaudeUsage
	$(SWIFTC) $(FLAGS) -target x86_64-apple-$(MIN_OS) $(SOURCES) -o build/x86_64/ClaudeUsage
	lipo -create build/arm64/ClaudeUsage build/x86_64/ClaudeUsage -output $(BIN)
	codesign --force --sign - $(APP) >/dev/null 2>&1 || true

run: $(BIN)
	open $(APP)

dump: $(BIN)
	$(BIN) --dump

test:
	mkdir -p build
	$(SWIFTC) -swift-version 5 Sources/UsageCore.swift Tests/main.swift -o build/tests
	./build/tests

# Uses made-up demo data, so no real session names end up in the repo.
screenshot: $(BIN)
	$(BIN) --snapshot docs/screenshot.png --demo

clean:
	rm -rf build
