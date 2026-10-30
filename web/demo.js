// Sample data for ?demo: the same standup as the iPhone app's demo mode.
const seg = (id, start, end, speaker, speaker_name, lang, text, conf) => ({
  id, start, end, speaker, speaker_name, lang, text, words: [], conf,
  producer: lang === 'ar' ? 'multi' : 'en', overlap: false, uncertain: conf < 0.7,
});

export const DEMO_RESULT = {
  transcript: {
    schema_version: 1,
    meeting: 'm_demo',
    segments: [
      seg('s_0001', 2.1, 7.8, 'omar', 'Omar', 'en', "Morning everyone. Let's keep it short today, we have the release on Thursday.", 0.94),
      seg('s_0002', 8.4, 15.2, 'S1', 'Mona', 'ar', 'تمام، أنا خلصت الـ onboarding screens امبارح وفاضل بس الـ dark mode.', 0.86),
      seg('s_0003', 15.9, 21.0, 'S1', 'Mona', 'en', "I'll push it for review before lunch.", 0.91),
      seg('s_0004', 21.8, 30.4, 'S2', null, 'ar', 'طيب والـ crash اللي كان بيحصل على الأيفون القديم؟ اتحل ولا لسه؟', 0.82),
      seg('s_0005', 31.0, 39.7, 'omar', 'Omar', 'ar', 'اتحل، كانت مشكلة في الـ memory لما بنحمّل الموديلات كلها مرة واحدة.', 0.88),
      seg('s_0006', 40.2, 47.5, 'omar', 'Omar', 'en', "Now we load one model at a time and it's stable on every device we tested.", 0.93),
      seg('s_0007', 48.1, 53.9, 'S2', null, 'ar', 'حلو جداً. يبقى نقفل الـ sprint النهاردة.', 0.79),
      { ...seg('s_0008', 54.3, 58.0, 'S1', 'Mona', 'en', 'Sounds good to me.', 0.66), why: 'low confidence' },
    ],
    gaps: [],
  },
  log: [
    'Segmentation: 9 turns, 0 overlapped',
    'Speakers: 3 found from 7 voice samples, 0 turns unlabeled',
    'Utterances: 8',
    '2.1–7.8s LID en 0.99 / ar 0.01 → English specialist (whisper-tiny.en) [en]',
    '8.4–21.0s LID ar 0.58 / en 0.42 → ambiguous, re-checking in 2s windows',
    '  8.4–15.2s LID ar 0.93 / en 0.07 → Arabic specialist (whisper-base) [ar]',
    '  15.2–21.0s LID en 0.96 / ar 0.04 → English specialist (whisper-tiny.en) [en]',
  ],
  timings: { segmentation: 1200, embedding: 5400, languageID: 6100, transcription: 21800 },
  duration: 754,
  wall: 34.5,
};

export const DEMO_CAPTIONS = {
  lines: [
    { language: 'en', text: "Okay, let's start with the numbers from last week." },
    { language: 'ar', text: 'الأرقام كانت أحسن من المتوقع، خصوصاً في الـ retention.' },
    { language: 'en', text: "That's great. What changed?" },
  ],
  draft: { language: 'ar', text: 'طيب، خلينا نشوف الـ' },
};
