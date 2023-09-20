all: buildapp

# build app to BossGPT.app
buildapp: release Info.plist
	mkdir -p BossGPT.app/Contents/MacOS BossGPT.app/Contents/Resources
	cp -f BossGPT BossGPT.app/Contents/MacOS/BossGPT
	cp -f Info.plist BossGPT.app/Contents/Info.plist
	# cp -f icon.icns BossGPT.app/Contents/Resources/icon.icns
	chmod +x BossGPT.app/Contents/MacOS/BossGPT
	codesign -s "Apple Distribution" BossGPT.app || true


release:
	$(MAKE) build TARGET=release

debug:
	$(MAKE) build TARGET=debug

build:
	swift build -c $(TARGET)
	cp -f .build/arm64-apple-macosx/$(TARGET)/bossgpt-swift BossGPT


Info.plist: Info.plist.template
	if [ -z "$(WS_URL)" ]; then echo "WS_URL is unset"; exit 1; fi
	sed -e "s|WS_URL_REPLACE_ME|$(WS_URL)|" Info.plist.template > Info.plist


dev:
	find Sources Package.swift | entr -rc sh -c "make debug -s && codesign -s 'Apple Development' BossGPT && ./BossGPT"


clean:
	rm -rf BossGPT BossGPT.app
	swift package clean


.PHONY: all build buildapp
