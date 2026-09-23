CC = clang
CFLAGS = -Wall -Wextra -O2
LDFLAGS = -F/System/Library/PrivateFrameworks -framework MultitouchSupport -framework CoreFoundation -framework IOKit

all: midi_haptic audio_haptic gui

midi_haptic: midi_haptic.c
	$(CC) $(CFLAGS) -o midi_haptic midi_haptic.c $(LDFLAGS)

audio_haptic: audio_haptic.c
	$(CC) $(CFLAGS) -o audio_haptic audio_haptic.c $(LDFLAGS)

gui: MidiHapticApp

MidiHapticApp: MidiHapticGui.swift HapticDriver.swift main.swift
	swiftc -O -o MidiHapticApp MidiHapticGui.swift HapticDriver.swift main.swift -framework AppKit -framework AVFoundation

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

clean:
	rm -rf midi_haptic audio_haptic MidiHapticApp $(APP) MidiHapticApp.iconset

.PHONY: all clean
