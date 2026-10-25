# Translation-path audit — 2026-10-25

This audit describes the current implementation after PR #46. Older implementation plans and
changelog entries remain historical records.

## Retained production paths

- Reader Add to Dictionary and Translate in Context use SelectionTranslationCoordinator and the
  shared ContextAnalysisService/OpenAI provider. Dictionary and training contextual refresh use
  ContextualTranslationCoordinator with the same service. No Apple word-by-word session is needed.
- DictionaryEntryDetailView still offers Translate Again, Force Translation and Retry Translation
  through DictionaryTranslationCoordinator. It protects manual/imported results until explicit
  replacement is confirmed.
- ContentView recovers legacy pending/interrupted translations without initiating model downloads
  at startup. DictionaryImportPreviewView queues imported entries without translations. ReaderView
  invalidates generated values and queues untranslated entries after a source-language change.
  These are supported Apple Translation consumers; removing the provider would strand those paths.
- SourceLanguage uses Apple language availability for the single-item import and reader pickers.
- VocabularyIndex uses SQLite for reading word forms, independently of morphological lemmas.

## Removed unreachable paths

A repository-wide call-site audit found no production caller for ContextualTranslationCoordinator's
translateWords, WordBreakdownBuilder, PolishDictionaryLookupCoordinator or PolishWiktionaryClient.
Only the former services and their tests referenced the Wiktionary parser/provider. Their old detail
UI had already been removed. Remove these services, Apple word-batch/session status/configuration
and obsolete parser/network tests; keep the active Apple session configuration beside its consumer.

BundledPolishLemmaResolver was called only by the retired Wiktionary provider as an inflected-form
fallback. No reader, reading-vocabulary index or current contextual-analysis service consumed it.
The 36,861,590-byte compressed SGJP pack, resolver and exclusive tools/polish-lemma-importer pack
builder therefore have no current consumer and are removed together. libsqlite3 remains for the
active reading-vocabulary index. The removed code and pack remain recoverable through Git history.

## Compatibility and validation

Keep WordHelpItem, PolishDictionaryResult and PolishDictionaryMeaning as Codable model values;
their historical names and field shapes are persistence contracts. Definitions retain source URL,
revision, examples, inflected-form and optional lemma metadata. Keep the former Polish diagnostic
file readable through a read-only adapter so dictionary exports still include existing events.
Dictionary v1/v2/v3 decoding, restoration and export stay unchanged. No user files are deleted and
no existing store is rewritten for cleanup; an installed morphology database may remain unused.

Regression coverage checks literal historical definition/diagnostic JSON, cloud refresh preserving
legacy help and manual translation, and complete backup restoration after a persistent-store reopen
(including optional lemma references). Existing tests continue to cover Apple request configuration,
translation-origin rules, import recovery, SwiftData migration and dictionary/learning UI behavior.
Actual Apple model downloads and cloud requests require device/network configuration and are not
asserted by simulator fixtures.
