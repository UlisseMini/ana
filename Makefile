all: buildapp

# build app to BossGPT.app
# @cp -f icon.icns BossGPT.app/Contents/Resources/icon.icns
buildapp: build Info.plist
	mkdir -p BossGPT.app/Contents/MacOS
	cp -f BossGPT BossGPT.app/Contents/MacOS/BossGPT
	cp -f Info.plist BossGPT.app/Contents/Info.plist
	mkdir -p BossGPT.app/Contents/Resources # donno if emptydir helps
	chmod +x BossGPT.app/Contents/MacOS/BossGPT
	codesign -s "Apple Development" BossGPT.app


build:
	swift build -c release
	cp -f .build/arm64-apple-macosx/release/bossgpt-swift BossGPT


Info.plist: Info.plist.template
	key=$$(grep -o 'sk-[A-Za-z0-9]\{48\}' .env); \
	if [[ -z "$$key" ]]; then \
		echo "No match"; \
		exit 1; \
	else \
		sed "s/sk-REPLACE-ME/$$key/" Info.plist.template > Info.plist; \
	fi


DEV_BIN=.build/arm64-apple-macosx/debug/bossgpt-swift

dev:
	find Sources Package.swift | entr -rc sh -c "swift build && $(DEV_BIN)"


.PHONY: all build buildapp
