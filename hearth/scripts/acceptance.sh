#!/usr/bin/env bash
# End-to-end acceptance path for HearthCore using hearthctl and real files.
#
#   scripts/acceptance.sh PHOTO_OR_VIDEO [MORE_MEDIA...]
#
# Env:
#   HEARTHCTL         path to hearthctl (default .build/debug/hearthctl)
#   WORK              working directory (default: a new temp dir)
#   WEATHER_BASE_URL  Open-Meteo base URL (default: real https://api.open-meteo.com)
#   OFFLINE_BASE_URL  unreachable URL used to simulate losing the network
#   LAT / LON         household location for weather (default 40.7128 / -74.0060)
set -euo pipefail
H="${HEARTHCTL:-.build/debug/hearthctl}"
WORK="${WORK:-$(mktemp -d)}"
WEATHER="${WEATHER_BASE_URL:-https://api.open-meteo.com}"
OFFLINE="${OFFLINE_BASE_URL:-http://127.0.0.1:9}"
LAT="${LAT:-40.7128}"; LON="${LON:--74.0060}"
S="$WORK/phone"; NAS="$WORK/nas"
export HEARTH_BACKUP_PASSPHRASE="${HEARTH_BACKUP_PASSPHRASE:-acceptance test passphrase}"
[[ $# -ge 1 ]] || { echo "usage: $0 MEDIA_FILE [...]"; exit 1; }
step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

step "1. Create household on 'phone' (no server, no account)"
$H init "$S" --household "Acceptance Household" --owner "Owner" --device "Owner iPhone"

step "2. Create real household entities"
HOUSE=$($H add-entity "$S" --kind home --name "Home" --lat "$LAT" --lon "$LON")
SHUTOFF=$($H add-entity "$S" --kind utility --name "Water main shutoff" --notes "Basement, north wall" --emergency)
$H link "$S" "$SHUTOFF" "$HOUSE" --type located_in >/dev/null
PROC=$($H add-procedure "$S" --title "Shut off the water" --step "Go to the basement north wall" --step "Turn the valve clockwise until it stops" --entity "$SHUTOFF" --emergency)

step "3. Capture/import media, attach to entity (stored encrypted, content-addressed)"
for f in "$@"; do $H import "$S" "$f" --entity "$SHUTOFF"; done
$H import "$S" "$1" --entity "$HOUSE" >/dev/null   # same bytes again: deduplicated
$H media "$S"

step "4. Connect one live source and refresh"
SRC=$($H add-weather "$S" --name "Home weather" --lat "$LAT" --lon "$LON" --entity "$HOUSE" | head -1)
$H refresh "$S" --base-url "$WEATHER"

step "5. Lose connectivity: refresh fails, values stay, marked OFFLINE"
$H refresh "$S" --base-url "$OFFLINE" || true

step "6. Modify while offline"
$H add-event "$S" --kind maintenance --title "Exercise shutoff valve" --entity "$SHUTOFF" --due-days 3 >/dev/null
$H add-entity "$S" --kind appliance --name "Water heater" --attr "model=AO Smith 50gal" >/dev/null
$H due "$S"

step "7. Reconnect: live data fresh again, history retained"
$H refresh "$S" --base-url "$WEATHER"
$H history "$S" "$SHUTOFF"

step "8. Second device joins via pairing, syncs through a shared folder; concurrent edits"
IDENT=$($H add-person "$S" --name "Partner" --role adult)
OUT=$($H enroll "$S" --identity "$IDENT" --device "Partner iPhone" --out "$WORK/pair.hearthpair")
CODE=$(echo "$OUT" | grep -Eo '[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}')
$H join "$WORK/partner" "$WORK/pair.hearthpair" --code "$CODE"
$H sync "$S" "$NAS"; $H sync "$WORK/partner" "$NAS"
$H search "$WORK/partner" shutoff
# Both devices rename the water heater without seeing each other's change:
HEATER=$($H search "$S" heater | cut -d' ' -f1)
$H set "$S" "$HEATER" name="Water heater (garage)"
$H set "$WORK/partner" "$HEATER" name="Water heater 50 gal" notes="Anode replaced 2025"
$H sync "$S" "$NAS" >/dev/null; $H sync "$WORK/partner" "$NAS" >/dev/null; $H sync "$S" "$NAS"
$H conflicts "$S"

step "9. Search and emergency info work with no network"
$H search "$S" valve
$H emergency "$S"

step "10. Open export (usable without Hearth)"
$H export "$S" "$WORK/export" --strip-location
EXP=$(ls -d "$WORK"/export/Hearth-Export-*)
ls "$EXP" "$EXP/media/originals"
for f in "$EXP"/media/originals/*; do
  want=$(basename "$f"); want="${want%%.*}"; got=$(sha256sum "$f" | cut -d' ' -f1)
  [[ "$want" == "$got" ]] && echo "original verified: $want"
done

step "11. Encrypted backup -> verify -> test restore -> restore on a 'new phone'"
BK=$($H backup "$S" "$WORK/usb")
echo "$BK"
KEY=$(echo "$BK" | grep -Eo '([A-Z2-9]{4}-){7}[A-Z2-9]{4}')
LOC=$(ls -d "$WORK"/usb/*.hearthbackup)
$H verify-backup "$LOC"
$H test-restore "$S" "$LOC" --recovery-key "$KEY"
$H restore "$LOC" "$WORK/new-phone" --recovery-key "$KEY"
$H search "$WORK/new-phone" valve
$H verify-media "$WORK/new-phone"

step "12. 'Device restart': reopen from disk"
$H info "$S"
$H sources "$S"

echo; echo "Acceptance path complete. Work dir: $WORK"
