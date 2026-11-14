# Installing Daytona Vision on Apple Vision Pro

Daytona Vision puts a full-size Daytona USA sit-down cab in your room, with hand-controlled wheel and pedals, a 3D track mode and a flat-window screen mode. The game itself is [daytona-arcade-recomp](https://github.com/alphanu1/daytona-arcade-recomp), used unmodified as the `upstream` submodule.

## Requirements

- A Mac with Xcode 27 or later and the visionOS platform
- Apple Vision Pro, in Developer Mode and paired with Xcode
- An Apple ID signed in to Xcode (a free account works; the app then needs re-installing every 7 days)
- [Homebrew](https://brew.sh): upstream's setup installs `cmake`, `ninja`, `python` and `git` with it
- Your own Daytona USA MAME ROM set: `daytona.zip` (Revision A, 1994) or `daytona93.zip` (Deluxe '93)
- Optional: a game controller (the hands work on their own)

## Game files

You need to supply your own game files. This repository contains none.

1. Make sure the submodule is checked out: `git submodule update --init`.
2. Copy your ROM set into `upstream/roms/`, named exactly `daytona.zip` or `daytona93.zip` (`.7z` works too).
3. Upstream's setup checks every file against the ROM set it was recompiled from, and says if yours was rejected.

## Build

From a checkout of this repository:

1. Generate the game code with upstream's setup (it uses Homebrew, and the Xcode command line tools):

   ```sh
   cd upstream && ./setup.sh && cd ..
   ```

2. Create `Config/Local.xcconfig` with your signing team and a bundle identifier prefix of your own. Add `ROMSET = daytona93` only for the Deluxe '93 set:

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.example
   ```

3. Make the game's first-run settings. Revision A comes set up as a linked twin cabinet; this sets a single cabinet, as upstream has you do once in its test menu:

   ```sh
   ./scripts/make_default_eeprom.sh
   ```

4. Open `DaytonaVision.xcodeproj`.

After updating `upstream`, run its setup again (and step 3) before rebuilding. Please don't share built apps: they contain code generated from the game.

## Install on Apple Vision Pro

1. Pick your Vision Pro as the run destination in Xcode and press Run.
2. On first launch, trust your developer certificate in Settings › General › VPN & Device Management if the headset asks.
3. In the app, choose your ROM set from Settings.

## Controls and known issues

- **Hands:** grab the wheel's rim and turn; pinch your right hand for gas and your left for brake (each pedal's hand and finger can be changed in Settings).
- **Controller:** left stick steers, triggers are gas and brake, shoulders shift, A B X Y are the VIEW buttons, Menu is Start, Options is Coin.
- **Cab:** tap the coin slot, then START on the dash. Pinch the screen to show the toolbar (Menu, Reset, Move, Arcade, Settings).
- **Screen** in the start volume plays in a flat window with a controller instead of the cab.
