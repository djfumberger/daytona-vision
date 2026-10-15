# Daytona Vision

A visionOS port of [daytona-arcade-recomp](https://github.com/alphanu1/daytona-arcade-recomp).

https://github.com/user-attachments/assets/f14820a3-acb5-4804-b396-4ca438be8a7d

Climb into a full-size sit-down cab in your own room. The race glows on its
CRT, the engine roars from the speakers either side of the marquee, and you
take the wheel with your own hands, or a controller if you'd rather. Turn the
lights down with the arcade room, or switch on 3D and watch the track run
deep into the screen.

Upstream is the `upstream/` submodule, used unmodified. No game data is in this
repository: the game code is generated from your own ROM set.

## Build

1. Put your ROM set in `upstream/roms/`: `daytona.zip` (Revision A, 1994) or
   `daytona93.zip` (Deluxe '93).
2. Generate the game code with upstream's setup:

       cd upstream && ./setup.sh && cd ..

3. Make `Config/Local.xcconfig` with your signing team, a bundle identifier
   prefix of your own (and the ROM set, if it is Deluxe '93):

       DEVELOPMENT_TEAM = ABCDE12345
       BUNDLE_ID_PREFIX = com.example
       ROMSET = daytona93

4. Make the game's first-run settings (Revision A comes set up as a linked
   twin cabinet; this sets a single cabinet, as upstream has you do once in
   its test menu):

       ./scripts/make_default_eeprom.sh

5. Open `DaytonaVision.xcodeproj` (Xcode 27 or later) and run on the Vision
   Pro. After updating upstream, run its setup again and rebuild.

Build it yourself from your own ROM set, and please don't share built apps:
they contain code generated from the game.
5. In the app, choose your ROM set from Settings.

## Playing

- **Hands:** grab the wheel's rim and turn. Pinch your right hand for gas, your
  left for brake; harder pinch, more pedal.
- **Controller:** left stick steers, triggers are gas and brake, shoulders
  shift, A B X Y are the VIEW buttons, Menu is Start, Options is Coin.
- **Cab:** tap the coin slot, then START on the dash.

Pinch the screen to show the toolbar: Menu, Reset, Move (the cab), Arcade
(expand into the arcade room, collapse out of it) and Settings (arcade room,
CRT effect, 3D, help, gas, wheel lock, volume, and the operator
buttons, Test and Service). The renderer is under Settings › Debug (GPU 3×
unless changed).

**Screen** in the start volume plays on a flat window instead of the cab, with
a controller. Its toolbar picks its shape: the original screen, or 16:10, 16:9
or 21:9 widescreen (more of the scene at the sides); the window keeps the shape
as it is resized.

## The cab model

The cab is `Core/Resources/Cab.usdz` (its Blender sources are not in this
repository). A replacement must be in metres, Y up, with the driver at +Z, and
use these names:

| Entity | Purpose |
| --- | --- |
| `EyePoint` | where the driver's eyes go |
| `CRT_Screen` (or `Screen`) | shows the game (UVs 0..1 over the picture) |
| `Wheel` | turned about its own Z axis; grab radius from its bounds |
| `SpeakerL`, `SpeakerR` | where the sound comes from |
| `ShifterLever` | tilted into the four gears |
| `PedalPivot_Gas`, `PedalPivot_Brake` | turned about -X as the pedals are pressed |
| `Button_START`, `Button_VIEW1`…`VIEW4`, `Button_TEST`, `Button_SERVICE`, `CoinDoor`, `CoinEntry_*` | tappable buttons |

Ambient occlusion, if baked in, is read through each part's second UV set.

## Licence

This project's code is GPL-3.0-or-later (`LICENSE`). Upstream, and the parts
ported from it (`Core/MetalRenderer.mm`, from its GPU renderer), are
BSD-3-Clause (`upstream/LICENSE`).

## Credits

The game runs on [daytona-arcade-recomp](https://github.com/alphanu1/daytona-arcade-recomp)
by Ben Templeman and contributors (BSD 3-Clause, see `upstream/LICENSE`).
Daytona USA is © SEGA. This project is not affiliated with or endorsed by SEGA,
and includes no game data.

From the maker of [Scanline](https://playscanline.com), retro games on Apple
Vision Pro.
