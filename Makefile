CC = clang
CFLAGS = -Wall -Wextra -O2
# На Intel приватного фреймворка нет в SDK для линовки — не страшно:
# все вызовы идут через dlopen/dlsym, линковать его не нужно.
LDFLAGS_ARM = -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework CoreFoundation -framework IOKit
LDFLAGS_INTEL = -framework CoreFoundation -framework IOKit
SWIFT_SRC = MidiHapticGui.swift HapticDriver.swift main.swift
SWIFT_FW = -framework AppKit -framework AVFoundation

all: midi_haptic audio_haptic gui

midi_haptic: midi_haptic.c
	$(CC) $(CFLAGS) -arch arm64 -o midi_haptic midi_haptic.c $(LDFLAGS_ARM)

audio_haptic: audio_haptic.c
	$(CC) $(CFLAGS) -arch arm64 -o audio_haptic audio_haptic.c $(LDFLAGS_ARM)

gui: MidiHapticApp

MidiHapticApp: $(SWIFT_SRC)
	swiftc -O -o MidiHapticApp $(SWIFT_SRC) $(SWIFT_FW)

APP = MidiHapticApp.app

app: midi_haptic audio_haptic MidiHapticApp
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp MidiHapticApp midi_haptic audio_haptic $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	python3 gen_icon.py
	iconutil -c icns MidiHapticApp.iconset -o $(APP)/Contents/Resources/AppIcon.icns
	rm -rf MidiHapticApp.iconset
	@echo "Готово: $(APP) — можно открывать двойным кликом"

# --- Отдельная версия для Intel-маков (x86_64) ---
INTEL_DIR = build-intel

intel: $(INTEL_DIR)/midi_haptic $(INTEL_DIR)/audio_haptic $(INTEL_DIR)/MidiHapticApp

$(INTEL_DIR)/midi_haptic: midi_haptic.c
	mkdir -p $(INTEL_DIR)
	$(CC) $(CFLAGS) -arch x86_64 -mmacosx-version-min=10.15 -o $@ midi_haptic.c $(LDFLAGS_INTEL)

$(INTEL_DIR)/audio_haptic: audio_haptic.c
	mkdir -p $(INTEL_DIR)
	$(CC) $(CFLAGS) -arch x86_64 -mmacosx-version-min=10.15 -o $@ audio_haptic.c $(LDFLAGS_INTEL)

$(INTEL_DIR)/MidiHapticApp: $(SWIFT_SRC)
	mkdir -p $(INTEL_DIR)
	swiftc -O -target x86_64-apple-macosx10.15 -o $@ $(SWIFT_SRC) $(SWIFT_FW)

app-intel: intel
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(INTEL_DIR)/MidiHapticApp $(INTEL_DIR)/midi_haptic $(INTEL_DIR)/audio_haptic $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	python3 gen_icon.py
	iconutil -c icns MidiHapticApp.iconset -o $(APP)/Contents/Resources/AppIcon.icns
	rm -rf MidiHapticApp.iconset
	@echo "Готово: $(APP) (Intel) — можно открывать двойным кликом"

# --- DMG ---
MidiHaptic-arm64.dmg: app
	rm -rf /tmp/dmgroot-arm64 $@
	mkdir -p /tmp/dmgroot-arm64
	cp -R $(APP) /tmp/dmgroot-arm64/
	ln -s /Applications /tmp/dmgroot-arm64/Applications
	cp README.md /tmp/dmgroot-arm64/README.txt
	hdiutil create -volname "MidiHaptic" -srcfolder /tmp/dmgroot-arm64 -ov -format UDZO -o $@
	rm -rf /tmp/dmgroot-arm64

MidiHaptic-intel.dmg: app-intel
	rm -rf /tmp/dmgroot-intel $@
	mkdir -p /tmp/dmgroot-intel
	cp -R $(APP) /tmp/dmgroot-intel/
	ln -s /Applications /tmp/dmgroot-intel/Applications
	cp README.md /tmp/dmgroot-intel/README.txt
	hdiutil create -volname "MidiHaptic" -srcfolder /tmp/dmgroot-intel -ov -format UDZO -o $@
	rm -rf /tmp/dmgroot-intel

clean:
	rm -rf midi_haptic audio_haptic typeclick MidiHapticApp $(APP) MidiHapticApp.iconset build-intel MidiHaptic-arm64.dmg MidiHaptic-intel.dmg MidiHaptic.dmg RhythmGame RhythmGame.app

.PHONY: all clean intel app-intel

# --- Печатная машинка: щелчок на каждое нажатие (нужен «Мониторинг ввода») ---
typeclick: typeclick.c
	$(CC) $(CFLAGS) -arch arm64 -o typeclick typeclick.c $(LDFLAGS_ARM) -framework ApplicationServices

# --- Ритм-игра на трекпаде ---
RhythmGame: RhythmGame.swift HapticDriver.swift game-main.swift
	swiftc -O -o RhythmGame RhythmGame.swift HapticDriver.swift game-main.swift $(SWIFT_FW)

RHYTHM_APP = RhythmGame.app

rhythm-app: RhythmGame midi_haptic
	rm -rf $(RHYTHM_APP)
	mkdir -p $(RHYTHM_APP)/Contents/MacOS $(RHYTHM_APP)/Contents/Resources
	cp RhythmGame midi_haptic $(RHYTHM_APP)/Contents/MacOS/
	cp RhythmGame-Info.plist $(RHYTHM_APP)/Contents/Info.plist
	python3 gen_icon.py
	iconutil -c icns MidiHapticApp.iconset -o $(RHYTHM_APP)/Contents/Resources/AppIcon.icns
	rm -rf MidiHapticApp.iconset
	@echo "Готово: $(RHYTHM_APP) — тапай по трекпаду в ритм"
