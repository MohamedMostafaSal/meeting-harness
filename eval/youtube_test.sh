#!/usr/bin/env bash
# Uses a YouTube video as a test set, on your own computer:
#   1. downloads its audio and captions (Arabic by default) with yt-dlp
#   2. runs the web harness on it with real models and scores it against the captions
#   3. packs the test set as yt-testset.zip, which the "youtube" workflow can also score
#      with the iPhone app's Core ML model (upload the zip somewhere private, pass its link)
#
# Needs Python 3, Node 18+, and ffmpeg. On Windows run it in Git Bash; if `python3` is the
# Microsoft Store stub, point PYTHON at a real one (PYTHON=py or PYTHON=/c/.../python.exe).
#   eval/youtube_test.sh "https://youtu.be/..." [minutes=10] [captions=ar] [preset=balanced]
set -euo pipefail
url="$1"; minutes="${2:-10}"; captions="${3:-ar}"; preset="${4:-balanced}"
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/yt"
py="${PYTHON:-python3}"
export PYTHONUTF8=1

"$py" -m pip install -q -U yt-dlp
"$py" "$root/eval/youtube_fetch.py" "$url" --out "$out" --minutes "$minutes" --captions "$captions"

(cd "$root/web" && npm install --no-audit --no-fund --silent && node test/youtube.js "$out" "$preset")

"$py" -c "import sys, zipfile; z = zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED); [z.write(f'{sys.argv[2]}/{n}', n) for n in ('audio.wav', 'cues.json', 'info.json')]" "$root/yt-testset.zip" "$out"
echo
echo "Scores: $out/score.md · transcript: $out/harness.md · captions vs harness: $out/side-by-side.md"
echo "Test set for CI: $root/yt-testset.zip (audio and captions; keep it private)"
