ARCH ?= $(shell uname -m)
# get version from latest git tag
VERSION=$(shell git describe --tags)

all: plist icons buildapps

buildapps:
	mkdir -p dist
	$(MAKE) release buildapp ARCH=x86_64 WS_URL=$(WS_URL)
	rm -rf dist/Ana-x86_64.app && mv Ana.app dist/Ana-x86_64.app
	$(MAKE) release buildapp ARCH=arm64 WS_URL=$(WS_URL)
	rm -rf dist/Ana-arm64.app && mv Ana.app dist/Ana-arm64.app

	zip -r dist/Ana-x86_64.app.zip dist/Ana-x86_64.app
	zip -r dist/Ana-arm64.app.zip dist/Ana-arm64.app

	@printf "\nSuccessfully built $(VERSION) into dist\n"


# build app to Ana.app
buildapp:
	mkdir -p Ana.app/Contents/MacOS Ana.app/Contents/Resources
	cp Ana Ana.app/Contents/MacOS/Ana
	cp Info.plist Ana.app/Contents/Info.plist
	cp Ana.icns Ana.app/Contents/Resources/Ana.icns
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

# creates Ana.icns
icons:
	mkdir Ana.iconset
	sips -z 16 16     images/icon.png --out Ana.iconset/icon_16x16.png
	sips -z 32 32     images/icon.png --out Ana.iconset/icon_16x16@2x.png
	sips -z 32 32     images/icon.png --out Ana.iconset/icon_32x32.png
	sips -z 64 64     images/icon.png --out Ana.iconset/icon_32x32@2x.png
	sips -z 128 128   images/icon.png --out Ana.iconset/icon_128x128.png
	sips -z 256 256   images/icon.png --out Ana.iconset/icon_128x128@2x.png
	sips -z 256 256   images/icon.png --out Ana.iconset/icon_256x256.png
	sips -z 512 512   images/icon.png --out Ana.iconset/icon_256x256@2x.png
	sips -z 512 512   images/icon.png --out Ana.iconset/icon_512x512.png
	sips -z 1024 1024 images/icon.png --out Ana.iconset/icon_512x512@2x.png
	iconutil -c icns Ana.iconset
	rm -R Ana.iconset


clean:
	rm -rf Ana Ana.app Info.plist Ana.icns


.PHONY: all build buildapp release debug dev icons clean plist
