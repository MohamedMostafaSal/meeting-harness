# Security and privacy

## Privacy model

meeting-harness is built to keep meetings on the device.

- **Audio and transcripts stay local.** The web prototype runs every model in the browser; the only network traffic is downloading the models (from Hugging Face) and the page's own scripts and fonts (from jsDelivr and Google Fonts). No audio, text or voice fingerprint is uploaded.
- **Enrolled voices** are stored in the browser's local storage on that device only, and can be removed from the *My voice* panel.
- **Exports** (Markdown, JSON Lines) leave the device only when you share or save them yourself.

Recording laws differ by country. Tell people when you record them.

## Reporting a vulnerability

Please report security issues privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**. Don't open a public issue for anything that could put users' recordings or data at risk.
