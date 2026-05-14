.PHONY: build clean install

SCHEME    = squawk
ARCHIVE   = build/squawk.xcarchive
EXPORT    = build
APP       = $(EXPORT)/squawk.app
INSTALL   = /Applications/Squawk.app

build:
	xcodebuild -scheme $(SCHEME) -configuration Release \
		-archivePath $(ARCHIVE) archive
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE) \
		-exportPath $(EXPORT) \
		-exportOptionsPlist ExportOptions.plist

install: build
	rm -rf "$(INSTALL)"
	cp -r "$(APP)" "$(INSTALL)"
	@echo "Installed to $(INSTALL)"
	@echo "If Gatekeeper blocks launch: right-click → Open → Open"

clean:
	rm -rf build/
