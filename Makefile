# ==============================================================================
# StrumKit iOS Makefile
# ==============================================================================

SHELL           := /bin/bash
PROJECT_NAME    := StrumKit
SCHEME          := StrumKit
BUNDLE_ID       := com.strumkit.tuner
DEVICE_NAME     ?= iPhone 17
DESTINATION     := platform=iOS Simulator,name=$(DEVICE_NAME)
DERIVED_DATA    := ./DerivedData
APP_BUNDLE      := $(DERIVED_DATA)/Build/Products/Debug-iphonesimulator/$(PROJECT_NAME).app

# Test builds are -O by default (see project.yml). SLOW=1 forces -Onone, which is ~112x
# slower and gets the test host killed partway through — useful only when debugging
# unoptimized behaviour, never for a suite run.
ifdef SLOW
TEST_DERIVED_DATA := $(DERIVED_DATA)
TEST_OPT_FLAGS    :=
else
TEST_DERIVED_DATA := ./DerivedDataO
TEST_OPT_FLAGS    := SWIFT_OPTIMIZATION_LEVEL=-O
endif

FORMATTER       := $(shell command -v xcbeautify 2>/dev/null)

# ANSI Colors
CYAN   := \033[36m
GREEN  := \033[32m
YELLOW := \033[33m
RED    := \033[31m
RESET  := \033[0m
BOLD   := \033[1m

.PHONY: help open run build test clean project xcode logs screenshot stop

# Default target: display help
help:
	@echo ""
	@echo -e "$(BOLD)$(CYAN)StrumKit Development Commands$(RESET)"
	@echo "──────────────────────────────────────────────────────"
	@echo -e "  $(GREEN)make open$(RESET)       Rebuild, install, and launch in iOS Simulator (alias: make run)"
	@echo -e "  $(GREEN)make build$(RESET)      Compile the StrumKit app target"
	@echo -e "  $(GREEN)make test$(RESET)       Run all 28 unit tests (YIN, tracking, audio fixtures)"
	@echo -e "  $(GREEN)make clean$(RESET)      Remove DerivedData and build artifacts"
	@echo -e "  $(GREEN)make project$(RESET)    Regenerate StrumKit.xcodeproj using XcodeGen"
	@echo -e "  $(GREEN)make xcode$(RESET)      Open the project in Xcode GUI"
	@echo -e "  $(GREEN)make logs$(RESET)       Stream live console logs from the app"
	@echo -e "  $(GREEN)make screenshot$(RESET) Save simulator screenshot to ./screenshot.png"
	@echo -e "  $(GREEN)make stop$(RESET)       Terminate running StrumKit process in simulator"
	@echo "──────────────────────────────────────────────────────"
	@echo -e "  $(YELLOW)DEVICE_NAME$(RESET)   Default is '$(DEVICE_NAME)'. Override via: make open DEVICE_NAME='iPhone 17 Pro'"
	@echo ""

# Rebuild, boot simulator if needed, install, and launch
open: build
	@echo -e "$(BOLD)$(CYAN)Ensuring Simulator is booted ($(DEVICE_NAME))...$(RESET)"
	@xcrun simctl boot "$(DEVICE_NAME)" 2>/dev/null || true
	@open -a Simulator
	@echo -e "$(BOLD)$(CYAN)Installing $(PROJECT_NAME)...$(RESET)"
	@xcrun simctl install booted $(APP_BUNDLE)
	@echo -e "$(BOLD)$(CYAN)Launching $(BUNDLE_ID)...$(RESET)"
	@xcrun simctl launch --terminate-running-process booted $(BUNDLE_ID)
	@echo -e "$(BOLD)$(GREEN)✓ StrumKit is running in $(DEVICE_NAME) Simulator!$(RESET)"

run: open

# Compile app target
build:
	@echo -e "$(BOLD)$(CYAN)Building $(PROJECT_NAME) for $(DEVICE_NAME)...$(RESET)"
ifeq ($(strip $(FORMATTER)),)
	@xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-destination "$(DESTINATION)" \
		-derivedDataPath $(DERIVED_DATA) \
		build
else
	@set -o pipefail && xcodebuild -project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-destination "$(DESTINATION)" \
		-derivedDataPath $(DERIVED_DATA) \
		build | $(FORMATTER)
endif

# Run all unit tests
#
# Uses $(TEST_DERIVED_DATA) and $(TEST_OPT_FLAGS) so the suite runs -O by default.
# Override with `make test SLOW=1` for a genuine -Onone run.
test:
	@echo -e "$(BOLD)$(CYAN)Running unit tests (-O, $(TEST_DERIVED_DATA))...$(RESET)"
ifeq ($(strip $(FORMATTER)),)
	@xcodebuild test \
		-project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-destination "$(DESTINATION)" \
		-derivedDataPath $(TEST_DERIVED_DATA) \
		$(TEST_OPT_FLAGS)
else
	@set -o pipefail && xcodebuild test \
		-project $(PROJECT_NAME).xcodeproj \
		-scheme $(SCHEME) \
		-destination "$(DESTINATION)" \
		-derivedDataPath $(TEST_DERIVED_DATA) \
		$(TEST_OPT_FLAGS) | $(FORMATTER)
endif

# Regenerate project from project.yml
project:
	@echo -e "$(BOLD)$(CYAN)Regenerating Xcode project with XcodeGen...$(RESET)"
	@xcodegen generate
	@echo -e "$(BOLD)$(GREEN)✓ $(PROJECT_NAME).xcodeproj updated.$(RESET)"

# Open in Xcode IDE
xcode:
	@open $(PROJECT_NAME).xcodeproj

# Clean build artifacts
clean:
	@echo -e "$(BOLD)$(YELLOW)Cleaning build artifacts...$(RESET)"
	@rm -rf $(DERIVED_DATA)
	@echo -e "$(BOLD)$(GREEN)✓ Clean complete.$(RESET)"

# Stream logs from app process
logs:
	@echo -e "$(BOLD)$(CYAN)Streaming logs for $(BUNDLE_ID) (Ctrl+C to exit)...$(RESET)"
	@xcrun simctl spawn booted log stream --predicate 'process == "$(PROJECT_NAME)"' --level debug

# Capture simulator screenshot
screenshot:
	@echo -e "$(BOLD)$(CYAN)Capturing screenshot...$(RESET)"
	@xcrun simctl io booted screenshot ./screenshot.png
	@echo -e "$(BOLD)$(GREEN)✓ Saved to ./screenshot.png$(RESET)"

# Terminate app process in simulator
stop:
	@echo -e "$(BOLD)$(YELLOW)Stopping $(BUNDLE_ID)...$(RESET)"
	@xcrun simctl terminate booted $(BUNDLE_ID) 2>/dev/null || true
	@echo -e "$(BOLD)$(GREEN)✓ Stopped.$(RESET)"
