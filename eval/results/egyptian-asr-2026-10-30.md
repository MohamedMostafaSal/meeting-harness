# Egyptian Arabic speech-to-text scores, 2026-10-30

100 clips (40.7 min) of Egyptian Arabic TV speech from the held-out MGB-3 test
split ([MightyStudent/Egyptian-ASR-MGB-3](https://huggingface.co/datasets/MightyStudent/Egyptian-ASR-MGB-3)
@ `0d30b10`, pre-computed Whisper features), seed 7. Scored with the app's
Arabic-aware normalization. Lower is better. Produced by `eval/score_models.py`
([run](https://github.com/MohamedMostafaSal/meeting-harness/actions/runs/41098555112)).

| Model | Size | CER | WER | Median clip CER | Exact clips | Speed (CI CPU) | Verdict |
|---|---|---|---|---|---|---|---|
| `alexstokes/whisper-small-eg2` | 242M | 1.1% | 1.5% | 0.0% | 91% | 0.23× | ❌ trained on these clips |
| `rahafvii/STT-EGY` | 242M | 5.9% | 10.9% | 0.0% | 76% | 0.23× | ❌ trained on these clips |
| **`tawreck-hasaballah/whisper-small-eg`** | 242M | **30.9%** | 63.2% | 25.8% | 0% | 0.23× | ✅ joint best honest score |
| **`xlpy/whisper-small-egyptian`** | 242M | **30.9%** | 59.5% | 24.1% | 0% | 0.18× | ✅ joint best; loops on some clips ([run](https://github.com/MohamedMostafaSal/meeting-harness/actions/runs/41106087095)) |
| `openai/whisper-small` | 242M | 39.6% | 68.3% | 30.3% | 0% | 0.24× | general model |
| `openai/whisper-base` | 73M | 53.4% | 88.6% | 40.1% | 0% | 0.08× | general model (web prototype, Light) |
| `MAdel121/whisper-medium-egy` | – | – | – | – | – | – | not scorable: the repository has no full model weights |
| `openai/whisper-large-v3-turbo` | – | – | – | – | – | – | can't be scored here: needs 128-bin features |

## What it means

- **Two published "Egyptian" models have seen this test set.** They reproduce the
  references verbatim, annotators' `...` pause marks and slips included. Their
  scores say nothing about real meetings. The scorer now flags any model that
  reproduces more than 30% of clips exactly.
- **Two honest Egyptian fine-tunes tie at 30.9% CER**, cutting character errors by
  22% relative to general Whisper small and 42% relative to Whisper base, at the
  same size as Whisper small. `xlpy/whisper-small-egyptian` has slightly better WER
  and median clip CER but sometimes loops (one clip repeats a word 60 times) and its
  model card documents no training data or license; `whisper-small-eg`'s card does. Its output reads like Egyptian dialect (`النهاردة`, `ما عندناش`,
  `عايزين`, `بقى`), where general Whisper drifts toward Standard Arabic spellings.
- **Whisper base is not usable for Egyptian.** It also loops (one clip repeats a
  word 40 times); the app's hallucination guard flags that as "repeats itself".
- **WER looks harsh** because broadcast references keep every hesitation and
  repetition (`ال ال`, `آ`, `...`). CER is the measure to compare by.
- **Still needed:** an independent test on real meetings (the user's own
  recordings), which no published model has trained on.

## Example (clip 5, 28 s)

- Reference: الـ hyperactive اللي هو النشاط الزايد ف النشاط الزايد ده حالة ما فيهاش عدو ما فيهاش عدوان ما عندناش عنف فيها …
- `whisper-base`: الهيب الاكدفتي اللهم مشتزين فالنشتزين دائع حالة مفعاش عدوان ما عندنا شعن فيها …
- `whisper-small`: الهيب الأكتبتي هي المشتة الزييد فالمشتة الزييد دا حالة ما فيها ايش عدو ما فيها ايش عدوان ما عندنا اش عنف فيها …
- `whisper-small-eg`: آه الهيب الأكتبتي اللي هو المشتاء الزايد فالمشتاء الزايد ده حالة ما فيهاش عد وما فيهاش عدوان ما عندناش عامف فيها …
