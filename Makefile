ARCH ?= $(shell uname -m)
# get version from latest git tag
VERSION=$(shell git describe --tags)

all: buildapps

buildapps:
	mkdir -p dist
	$(MAKE) buildapp ARCH=x86_64 WS_URL=$(WS_URL)
	rm -rf dist/BossGPT-x86_64.app && mv BossGPT.app dist/BossGPT-x86_64.app
	$(MAKE) buildapp ARCH=arm64 WS_URL=$(WS_URL)
	rm -rf dist/BossGPT-arm64.app && mv BossGPT.app dist/BossGPT-arm64.app

	zip -r dist/BossGPT-x86_64.app.zip dist/BossGPT-x86_64.app
	zip -r dist/BossGPT-arm64.app.zip dist/BossGPT-arm64.app

	@printf "\nSuccessfully built $(VERSION) into dist\n"


# build app to BossGPT.app
buildapp: release plist
	mkdir -p BossGPT.app/Contents/MacOS BossGPT.app/Contents/Resources
	cp BossGPT BossGPT.app/Contents/MacOS/BossGPT
	cp Info.plist BossGPT.app/Contents/Info.plist
	# cp -f icon.icns BossGPT.app/Contents/Resources/icon.icns
	chmod +x BossGPT.app/Contents/MacOS/BossGPT
	codesign -s "Apple Distribution" BossGPT.app || true


release:
	$(MAKE) build TARGET=release ARCH=$(ARCH)

debug:
	$(MAKE) build TARGET=debug ARCH=$(ARCH)

build:
	arch -$(ARCH) sh -c 'swift build -c $(TARGET)'
	cp .build/$(ARCH)-apple-macosx/$(TARGET)/bossgpt BossGPT


plist:
	if [ -z "$(WS_URL)" ]; then echo "WS_URL is unset"; exit 1; fi
	sed \
		-e "s|WS_URL_REPLACE_ME|$(WS_URL)|" \
		-e "s|VERSION_REPLACE_ME|$(VERSION)|" \
		Info.plist.template > Info.plist


dev:
	find Sources Package.swift | entr -rc sh -c "make debug -s && echo Signing... && codesign -s 'Apple Development' BossGPT && VERSION=$(VERSION) ./BossGPT"


clean:
	rm -rf BossGPT BossGPT.app Info.plist


.PHONY: all build buildapp
