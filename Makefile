ARCH ?= $(shell uname -m)
# get version from latest git tag
VERSION=$(shell git describe --tags)

all: buildapps

buildapps:
	mkdir -p dist
	$(MAKE) release plist buildapp ARCH=x86_64 WS_URL=$(WS_URL)
	rm -rf dist/Ana-x86_64.app && mv Ana.app dist/Ana-x86_64.app
	$(MAKE) release plist buildapp ARCH=arm64 WS_URL=$(WS_URL)
	rm -rf dist/Ana-arm64.app && mv Ana.app dist/Ana-arm64.app

	zip -r dist/Ana-x86_64.app.zip dist/Ana-x86_64.app
	zip -r dist/Ana-arm64.app.zip dist/Ana-arm64.app

	@printf "\nSuccessfully built $(VERSION) into dist\n"


# build app to Ana.app
buildapp:
	mkdir -p Ana.app/Contents/MacOS Ana.app/Contents/Resources
	cp Ana Ana.app/Contents/MacOS/Ana
	cp Info.plist Ana.app/Contents/Info.plist
	# cp -f icon.icns Ana.app/Contents/Resources/icon.icns
	chmod +x Ana.app/Contents/MacOS/Ana
	codesign -s "Apple Distribution" Ana.app || true


release:
	$(MAKE) build TARGET=release ARCH=$(ARCH)

debug:
	$(MAKE) build TARGET=debug ARCH=$(ARCH)

build:
	arch -$(ARCH) sh -c 'swift build -c $(TARGET)'
	cp .build/$(ARCH)-apple-macosx/$(TARGET)/ana Ana


plist:
	if [ -z "$(WS_URL)" ]; then echo "WS_URL is unset"; exit 1; fi
	sed \
		-e "s|WS_URL_REPLACE_ME|$(WS_URL)|" \
		-e "s|VERSION_REPLACE_ME|$(VERSION)|" \
		Info.plist.template > Info.plist


dev:
	find Sources Package.swift | entr -rc sh -c "make debug buildapp -s && ./Ana.app/Contents/MacOS/Ana"


clean:
	rm -rf Ana Ana.app Info.plist


.PHONY: all build buildapp
