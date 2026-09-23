# Legacy contextual-analysis store generator

This generator compiles the frozen pre-migration schema in `LegacyLibraryModels.swift`, seeds all
data that the Foundation Models migration must preserve, closes the temporary `ModelContainer`,
and copies the complete SQLite store set to `Tests/Fixtures/FoundationModelsLegacyStore`.

Regenerate the fixture with:

```sh
bash tools/legacy-context-store-fixture/generate.sh
```

The committed fixture was generated from commit `a4a8f4a` plus the Stage 1 domain-only files. Its
fixed identifiers are asserted in `LegacyContextStoreFixtureTests`.
