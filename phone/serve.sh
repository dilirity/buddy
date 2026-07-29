#!/bin/sh
# Serve the phone body on the LAN. Links in the LIVE brain's sprites.json so
# the phone shows buddy's current evolved look, not the repo seed.
cd "$(dirname "$0")" || exit 1
ln -sf "$HOME/.buddy/brain/sprites.json" sprites.json
IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1)
echo "open on phone:  http://$IP:8765/"
python3 -m http.server 8765
