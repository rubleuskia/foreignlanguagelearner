# Foundation Models feasibility probe

This is an isolated DEBUG-only iOS 26.0 app for the physical-device gate in
`docs/FOUNDATION_MODELS_CONTEXTUAL_TRANSLATION_PLAN.md`. It is not linked to the production app.

Generate and build it with:

```sh
cd tools/foundation-models-probe
xcodegen generate
xcodebuild build \
  -project FoundationModelsFeasibilityProbe.xcodeproj \
  -scheme FoundationModelsFeasibilityProbe \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

For the gate, install the Debug app on an eligible physical device, export the normal and
airplane-mode reports, have a Polish/Russian bilingual evaluator score every attempt, and copy
the measured summary into `docs/FOUNDATION_MODELS_FEASIBILITY.md`. A simulator result is not a
substitute for this procedure.
