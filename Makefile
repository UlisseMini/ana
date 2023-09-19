all: buildapp

# build app to BossGPT.app
# @cp -f Info.plist BossGPT.app/Contents/Info.plist
# @cp -f icon.icns BossGPT.app/Contents/Resources/icon.icns
buildapp: build
	@mkdir -p BossGPT.app/Contents/MacOS
	@cp -f BossGPT BossGPT.app/Contents/MacOS/BossGPT
	@chmod +x BossGPT.app/Contents/MacOS/BossGPT


build:
	@swift build -c release
	@cp -f .build/arm64-apple-macosx/release/bossgpt-swift BossGPT


.PHONY: all build buildapp
