APP_NAME     := PDFViewer
BUILD_DIR    := ../build
APP_BUNDLE   := $(BUILD_DIR)/$(APP_NAME).app
SRCS         := main.m AppDelegate.m MuPDFRenderer.m
BIN          := $(BUILD_DIR)/$(APP_NAME)

CC           := clang
OBJCFLAGS    := -fobjc-arc -fmodules -I/opt/homebrew/include -Wall -O2
LDFLAGS      := -framework Cocoa \
                -L/opt/homebrew/lib \
                -lmupdf -lmupdf-third \
                -Wl,-rpath,/opt/homebrew/lib

.PHONY: all bundle run open clean

all: $(BIN)

# ── Standalone executable ──────────────────────────────────────────
$(BIN): $(SRCS) | $(BUILD_DIR)
	$(CC) $(OBJCFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ── .app bundle ────────────────────────────────────────────────────
bundle: $(BIN) Info.plist
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp $(BIN) "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"
	cp Info.plist "$(APP_BUNDLE)/Contents/"
	# Copy dylibs into bundle and fix paths
	@for lib in libmupdf.dylib libmupdf-third.dylib; do \
		src="/opt/homebrew/lib/$$lib"; \
		if [ -f "$$src" ]; then \
			cp "$$src" "$(APP_BUNDLE)/Contents/MacOS/"; \
			install_name_tool -change "$$src" \
				"@executable_path/$$lib" \
				"$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true; \
		fi \
	done
	@echo "✓ App bundle created at $(APP_BUNDLE)"

# ── Run from terminal ──────────────────────────────────────────────
run: $(BIN)
	$(BIN)

# ── Open .app bundle via Finder ────────────────────────────────────
open: bundle
	open "$(APP_BUNDLE)"

# ── DMG package ───────────────────────────────────────────────────
DMG_DIR    := $(BUILD_DIR)/dmg-staging
DMG        := $(BUILD_DIR)/PDFViewer.dmg

dmg: bundle
	rm -rf "$(DMG_DIR)"
	mkdir -p "$(DMG_DIR)"
	cp -R "$(APP_BUNDLE)" "$(DMG_DIR)/"
	ln -s /Applications "$(DMG_DIR)/Applications"
	rm -f "$(DMG)"
	hdiutil create -fs APFS -format UDZO \
	  -srcfolder "$(DMG_DIR)" \
	  -volname "PDFViewer" \
	  "$(DMG)"
	rm -rf "$(DMG_DIR)"
	@echo "✓ DMG created at $(DMG)"

# ── Clean ──────────────────────────────────────────────────────────
clean:
	rm -rf $(BUILD_DIR)
