PROJECT   := MenuDock.xcodeproj
SCHEME    := MenuDock
CONFIG    := Debug
DERIVED   := .build
APP       := $(DERIVED)/Build/Products/$(CONFIG)/MenuDock.app
INSTALLED := /Applications/MenuDock.app
SUPPORT   := $(HOME)/Library/Application Support/MenuDock
ICON      := Resources/AppIcon.icns

.PHONY: all project build run stop install uninstall icon clean reset logs config

all: build

## Regenerate MenuDock.xcodeproj from project.yml (run after adding/removing source files)
project: $(ICON)
	xcodegen generate

# The icon is generated, not checked in, so a fresh clone builds without a missing-resource
# error. `make icon` forces a redraw after editing the generator.
$(ICON):
	@swift Tools/GenerateAppIcon/main.swift

## Redraw the app icon from Tools/GenerateAppIcon
icon:
	@swift Tools/GenerateAppIcon/main.swift

build: project
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-derivedDataPath $(DERIVED) build | \
		grep -E "(error|warning:|BUILD)" || true

## Build, replace any running copy, and launch
run: build stop
	@open "$(APP)"
	@echo "MenuDock is running — look in the menu bar. 'make stop' to quit."

stop:
	@pkill -x MenuDock 2>/dev/null || true
	@sleep 0.3

## Install into /Applications, so MenuDock is searchable and launchable like any other app
install: build stop
	@rm -rf "$(INSTALLED)"
	@cp -R "$(APP)" "$(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "Installed $(INSTALLED) — search for it in Spotlight or Applications."

uninstall: stop
	@rm -rf "$(INSTALLED)"
	@echo "Removed $(INSTALLED) (settings in $(SUPPORT) are untouched)."

clean:
	@rm -rf $(DERIVED)

## Delete the user's configuration and custom icons — starts the app from scratch
reset: stop
	@rm -rf "$(SUPPORT)"
	@echo "Removed $(SUPPORT)"

## Tail MenuDock's os_log output
logs:
	@log stream --predicate 'subsystem == "com.kai.MenuDock"' --level debug

## Print the current on-disk configuration
config:
	@cat "$(SUPPORT)/config.json" 2>/dev/null || echo "No configuration yet."
