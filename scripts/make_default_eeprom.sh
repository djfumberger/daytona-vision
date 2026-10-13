#!/bin/sh
# The game settings the app starts from on its first run:
# Core/Resources/default_eeprom.bin. Not committed (the game writes it), so
# make it once after upstream's setup:
#
#   ./scripts/make_default_eeprom.sh            the ROM set in Config/Local.xcconfig
#   ./scripts/make_default_eeprom.sh daytona93  or this one
#
# Revision A (daytona) comes set up as a linked twin cabinet that waits for a
# second one. Upstream has you set a single cabinet once in its test menu; this
# does the same, driving the menu with set_single_cabinet.txt in upstream's
# headless runner (single cabinet, deluxe, USA). Deluxe '93 needs no change:
# its own first-boot settings are saved as they are.
set -e
cd "$(dirname "$0")/.."

ROMSET=${1:-$(sed -n 's/^ROMSET *= *//p' Config/Local.xcconfig 2>/dev/null)}
ROMSET=${ROMSET:-daytona}
case "$ROMSET" in
    daytona)   BUILD=upstream/build-daytona; INPUTS="--inputs scripts/set_single_cabinet.txt" ;;
    daytona93) BUILD=upstream/build; INPUTS= ;;
    *) echo "unknown ROM set: $ROMSET (daytona or daytona93)" >&2; exit 1 ;;
esac

if [ ! -x "$BUILD/m2run" ] || [ ! -d "$BUILD/rom_cache/$ROMSET" ]; then
    echo "No $BUILD/m2run or $BUILD/rom_cache/$ROMSET: run upstream's setup first (cd upstream && ./setup.sh)" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
"$BUILD/m2run" "$BUILD/rom_cache/$ROMSET" 3000 $INPUTS --save-nvram "$WORK" > /dev/null
cp "$WORK/ioboard_eeprom.bin" Core/Resources/default_eeprom.bin
echo "Core/Resources/default_eeprom.bin: $ROMSET's first-run settings"
