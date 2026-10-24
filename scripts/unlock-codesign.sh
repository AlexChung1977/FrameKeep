#!/bin/sh
# Unlock the local codesign keychain before Xcode signs the app.
# The certificate stays the same across rebuilds, so screen-recording
# permission does not have to be granted again after every compile.
KEYCHAIN="$HOME/Library/Application Support/Framekeep/codesign/framekeep.keychain-db"
PASSFILE="$HOME/Library/Application Support/Framekeep/codesign/keychain-password"
if [ -f "$KEYCHAIN" ] && [ -f "$PASSFILE" ]; then
  security unlock-keychain -p "$(cat "$PASSFILE")" "$KEYCHAIN"
fi
