#!/bin/bash
# Codex allows exactly one `notify` program, and this machine already points it
# at Codex Computer Use. Fan out to both instead of replacing it: the original
# runs first and its arguments are forwarded untouched, so if LLMPet ever breaks
# the existing integration keeps working.
ORIGINAL="/Users/isidropasman/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"

[ -x "$ORIGINAL" ] && "$ORIGINAL" turn-ended "$@" &

"$HOME/Desktop/Isidro/MacTools/llmpet/hooks/llmpet-codex.sh" "${@: -1}" &

wait
