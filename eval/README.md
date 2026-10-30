# Model evaluation

`score_models.py` scores speech-to-text models on Egyptian Arabic so the Arabic
specialist is chosen on evidence. It uses the same Arabic-aware normalization as
the app, so its numbers match the web prototype's *Check accuracy* panel.

Run it from **Actions › eval › Run workflow**, or locally:

```sh
pip install -r eval/requirements.txt
python eval/score_models.py --limit 100
```

Results (a Markdown table with examples, and JSON) go to `eval/results/` and the
GitHub job summary.

The test set is the MGB-3 Egyptian Arabic broadcast test split. Some fine-tunes
were trained on MGB-3's training split, which favours them here; the table marks
them. Real meeting recordings are the independent check.
