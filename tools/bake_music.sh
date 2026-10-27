#!/usr/bin/env bash
# Genera la música de la versión web: WAV con tools/bake_music.gd y OGG con ffmpeg en audio/music/.
# Uso: GODOT=/ruta/godot tools/bake_music.sh
set -euo pipefail
cd "$(dirname "$0")/.."
"${GODOT:-godot}" --headless --path . --script res://tools/bake_music.gd
mkdir -p audio/music
for wav in build/music_wav/*.wav; do
	id="$(basename "$wav" .wav)"
	ffmpeg -loglevel error -y -i "$wav" -c:a libvorbis -q:a 4 "audio/music/$id.ogg"
done
ls -l audio/music
