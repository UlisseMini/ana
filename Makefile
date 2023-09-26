ARCH ?= $(shell uname -m)

all: buildapps

buildapps:
	mkdir -p dist
	$(MAKE) buildapp ARCH=x86_64 WS_URL=$(WS_URL)
	rm -rf dist/BossGPT-x86_64.app && mv BossGPT.app dist/BossGPT-x86_64.app
	$(MAKE) buildapp ARCH=arm64 WS_URL=$(WS_URL)
	rm -rf dist/BossGPT-arm64.app && mv BossGPT.app dist/BossGPT-arm64.app


# build app to BossGPT.app
buildapp: release Info.plist
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


Info.plist:
	if [ -z "$(WS_URL)" ]; then echo "WS_URL is unset"; exit 1; fi
	sed -e "s|WS_URL_REPLACE_ME|$(WS_URL)|" Info.plist.template > Info.plist


dev:
	find Sources Package.swift | entr -rc sh -c "make debug -s && codesign -s 'Apple Development' BossGPT && ./BossGPT"


clean:
	rm -rf BossGPT BossGPT.app Info.plist


.PHONY: all build buildapp
