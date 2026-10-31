#!/usr/bin/env bash
# Uses a YouTube video as a test set, on your own computer:
#   1. downloads its audio and captions (Arabic by default) with yt-dlp
#   2. runs the web harness on it with real models and scores it against the captions
#   3. packs the test set as yt-testset.zip, which the "youtube" workflow can also score
#      with the iPhone app's Core ML model (upload the zip somewhere private, pass its link)
#
# Needs Python 3, Node 18+, and ffmpeg.
#   eval/youtube_test.sh "https://youtu.be/..." [minutes=10] [captions=ar] [preset=balanced]
set -euo pipefail
url="$1"; minutes="${2:-10}"; captions="${3:-ar}"; preset="${4:-balanced}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/yt"

python3 -m pip install -q -U yt-dlp
python3 "$root/eval/youtube_fetch.py" "$url" --out "$out" --minutes "$minutes" --captions "$captions"

(cd "$root/web" && npm install --no-audit --no-fund --silent && node test/youtube.js "$out" "$preset")

(cd "$out" && rm -f ../yt-testset.zip && zip -q ../yt-testset.zip audio.wav cues.json info.json)
echo
echo "Scores: $out/score.md · transcript: $out/harness.md · captions vs harness: $out/side-by-side.md"
echo "Test set for CI: $root/yt-testset.zip (audio and captions; keep it private)"
