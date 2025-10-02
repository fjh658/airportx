# -----------------------------------------------------------------------------
# Makefile — universal macOS build for airportx (Swift)
# -----------------------------------------------------------------------------

BIN_NAME ?= airportx
MODULE_CACHE_PATH ?= .swift_module_cache
VERSION ?= $(shell \
  if [ -f airportx/airportx.swift ]; then \
    grep -Eo 'private static let version *= *"[^"]+"' airportx/airportx.swift | sed -E 's/[^"]*"([^"]+)"/\1/'; \
  elif [ -f airportx.swift ]; then \
    grep -Eo 'private static let version *= *"[^"]+"' airportx.swift | sed -E 's/[^"]*"([^"]+)"/\1/'; \
  elif [ -f airportx/Formula/airportx.rb ]; then \
    grep -Eo 'version *"[^"]+"' airportx/Formula/airportx.rb | head -n 1 | sed -E 's/version *"([^"]+)"/\1/'; \
  elif [ -f airportx.rb ]; then \
    grep -Eo 'version *"[^"]+"' airportx.rb | head -n 1 | sed -E 's/version *"([^"]+)"/\1/'; \
  else \
    echo "0.0.0"; \
  fi \
)
VERSION_CLEAN := $(shell printf '%s' "$(VERSION)" | LC_ALL=C tr -cd '0-9A-Za-z._-')

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

# Build a versioned tarball in the dist directory
.PHONY: dist
dist: universal
	@mkdir -p dist
	@tarfile="dist/$(BIN_NAME)-$(VERSION_CLEAN)-universal.tar.gz"; \
	/bin/echo "Packaging $$tarfile"; \
	tar -czf "$$tarfile" "$(BIN_NAME)" && /bin/echo "Created $$tarfile"

# Update the Homebrew formula file with the current version and sha256 of the packaged tarball.
.PHONY: update_formula
update_formula: dist
	@formula_file="./Formula/airportx.rb"; \
	[ -f "$$formula_file" ] || formula_file="airportx.rb"; \
	if [ -f "$$formula_file" ]; then \
	  tarball="dist/$(BIN_NAME)-$(VERSION_CLEAN)-universal.tar.gz"; \
	  new_sha=$$(shasum -a 256 "$$tarball" | awk '{print $$1}'); \
	  awk -v ver="$(VERSION_CLEAN)" -v sha="$$new_sha" -v tarname="$(BIN_NAME)-$(VERSION_CLEAN)-universal.tar.gz" '\
	    BEGIN{} \
	    { \
	      if ($$0 ~ /^[[:space:]]*version[[:space:]]*"/) { sub(/"[^"]+"/,"\"" ver "\""); } \
	      if ($$0 ~ /airportx-[0-9.]+-universal\.tar\.gz/) { gsub(/airportx-[0-9.]+-universal\.tar\.gz/, tarname); } \
	      if ($$0 ~ /^[[:space:]]*sha256[[:space:]]*"/) { sub(/"[a-f0-9]+"/,"\"" sha "\""); } \
	      print $$0; \
	    }' "$$formula_file" > "$$formula_file.tmp" && mv "$$formula_file.tmp" "$$formula_file"; \
	  echo "Formula updated to $(VERSION_CLEAN) with sha256 $$new_sha"; \
	else \
	  echo "Formula file not found; skipping update."; \
	fi

# Build and package, then update the Homebrew formula
.PHONY: release
release: dist update_formula
	@echo "Release artifacts prepared."

clean:
	@rm -f ./$(BIN_NAME)
	@echo "🧹 Clean complete"
