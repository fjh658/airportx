# -----------------------------------------------------------------------------
# Makefile — universal macOS build for airportx (Swift)
# -----------------------------------------------------------------------------

BIN_NAME ?= airportx
MODULE_CACHE_PATH ?= .swift_module_cache

all: universal

x86_64:
	@echo "🔨 Building x86_64 slice (min 10.13)…"
	@mkdir -p $(MODULE_CACHE_PATH)
	@xcrun swiftc -parse-as-library -O \
		-target x86_64-apple-macos10.13 \
		-module-cache-path $(MODULE_CACHE_PATH) \
		-o /tmp/$(BIN_NAME)-x86_64 airportx.swift
	@echo "→ /tmp/$(BIN_NAME)-x86_64"

arm64:
	@echo "🔨 Building arm64 slice (min 11.0)…"
	@xcrun swiftc -parse-as-library -O \
		-target arm64-apple-macos11.0 \
		-module-cache-path $(MODULE_CACHE_PATH) \
		-o /tmp/$(BIN_NAME)-arm64 airportx.swift
	@echo "→ /tmp/$(BIN_NAME)-arm64"

universal: x86_64 arm64
	@echo "📦 Merging into universal binary ./$(BIN_NAME)…"
	@lipo -create -output ./$(BIN_NAME) /tmp/$(BIN_NAME)-x86_64 /tmp/$(BIN_NAME)-arm64
	@chmod +x ./$(BIN_NAME)
	@echo "✅ Done: ./$(BIN_NAME)"
	@echo "⚠️  Optional (drop Location / read system plist w/o sudo for the binary only):"
	@echo "    sudo chown root ./$(BIN_NAME) && sudo chmod +s ./$(BIN_NAME)"

clean:
	@rm -f ./$(BIN_NAME)
	@echo "🧹 Clean complete"
