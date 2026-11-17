#!/bin/zsh
# Renders each sheet at 2x, light and dark, into docs/design/. Requires Google Chrome.
cd "$(dirname "$0")"
C="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for f in 0*.html; do n=${f%.html}
 H=$("$C" --headless=new --disable-gpu --virtual-time-budget=2000 --window-size=1700,3000 --dump-dom "file://$PWD/$f" 2>/dev/null | grep -o 'H=[0-9][0-9]*' | head -1 | cut -d= -f2)
 H=$((H+32))
 for m in light dark; do
  q=""; [ $m = dark ] && q="?dark"
  "$C" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=2 --window-size=1700,$H --screenshot="../$n-$m.png" "file://$PWD/$f$q" >/dev/null 2>&1
 done
done
