# Lab tasks

The queue for the lab session on the maintainer's laptop (see [handover.md](handover.md)). The cloud
session adds tasks here on `master`; the lab does the first one still marked **open**, then:

1. writes results to `eval/results/` (or `eval/lab/` for raw notes) on branch `lab/live-asr`,
2. marks the task **done** in this file on that branch, with a one-line summary and the results file,
3. pushes `lab/live-asr` and stops.

Measure and report only: no changes to `App/`, `Sources/`, `web/` (local instrumentation is fine,
don't commit it), the workflows, or `master`. Ask the maintainer before sending audio to any cloud
service. Keep test audio and captions (`yt/`, `yt-testset.zip`) out of git.

---

## 1. YouTube test set and the current harness on it (done)

Done 2026-10-31: CER 140.8% (Balanced) and 275.8% (Light) against automatic captions, mostly repetition loops; about 65–70% with loops collapsed. Results: [eval/results/youtube-testset-2026-10-31.md](../eval/results/youtube-testset-2026-10-31.md).

Lab brief step 1. Run `eval/youtube_test.sh "https://youtu.be/dkeu6gi3mAc" 10 ar balanced` (Git Bash,
or its steps by hand). Report `yt/info.json`, `yt/score.md`, and 3 short excerpts from
`yt/side-by-side.md` that show the typical errors. Then run it again with `light` and report that
score too.

## 2. Current live captions, measured (open)

Lab brief step 2. Serve `web/`, record in Chrome while the first 10 minutes of the video play, once with
Light and once with Balanced. Report: delay from sentence end to committed caption, CPU (Task Manager),
how often captions loop and on what audio, and the laptop's CPU/GPU model and RAM.
