# Foreign Language Learner

Native SwiftUI iPhone and iPad app, targeting iOS 18+. Includes a local media library with single-file and multi-track audiobook import, synchronized selectable transcripts, an Apple Translation-powered phrase dictionary, interactive learning rounds, portable JSON dictionary files, simulator CI, and signed publishing infrastructure. See [media library details](docs/MEDIA_LIBRARY.md).

## Start developing

1. Install full Xcode 26.6 or later, open it once, and install an iOS simulator runtime.
2. Select it: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
3. Install [Homebrew](https://brew.sh), then run `brew install xcodegen` (2.45 or newer).
4. Run `bash scripts/bootstrap.sh`.
5. Open `ForeignLanguageLearner.xcodeproj` and run the `ForeignLanguageLearner` scheme on a simulator.

For a physical device, set your development team in Xcode and use a registered bundle identifier. Project settings are generated: persist changes in `project.yml`, then regenerate. The default bundle identifier is a placeholder until registered in your Apple account.

If a newly added Swift type is reported as missing, regenerate the ignored Xcode project with `bash scripts/bootstrap.sh` before changing imports or access control. See [generated project drift prevention](docs/PREVENTING_GENERATED_PROJECT_DRIFT.md) for the diagnosis and workflow.

## Generate subtitles from a book and audio

Use the standalone [TXT + audio subtitle utility](tools/subtitle-aligner/README.md) to align a matching transcript and narration into SRT/WebVTT for the app. Its README covers installation, Polish examples, chapter offsets, validation, and import steps.

For audiobooks already divided into tracks, the batch command consumes explicit word ranges from a v1 book manifest and publishes a local `.book.zip` only when every track succeeds.

## Tests

```sh
bash scripts/test.sh
# To choose a particular installed simulator:
SIMULATOR_ID=<simulator-udid> bash scripts/test.sh
```

Unit tests cover subtitle parsing, timing lookup, Unicode ranges, dictionary persistence, learning levels, and JSON dictionary transfer. UI tests exercise the empty library, import sheet, and dictionary navigation. Tests use in-memory state, with no network or credentials. Add model tests under `Tests/Unit` and user journey tests under `Tests/UI`; regenerate the project after adding files. Xcode also runs both suites with Command-U. Test results and coverage are saved in `build/*.xcresult`; open these in Xcode.

## Automation

- **iOS CI:** pull requests, pushes to `main`, and manual runs; unit/UI tests with coverage, unsigned device Release compilation, and test artifacts.
- **Publish iOS:** manual runs from `main`, after tests pass; signed archive and upload to TestFlight or an App Store draft. App Store review submission and public release remain manual.
- Dependabot checks GitHub Actions weekly.

Workflows become available after these files are pushed to GitHub. See [release setup](docs/RELEASING.md) for Apple credentials, GitHub environment configuration, and first release steps.

## Layout

- `App/`: SwiftUI screens, UIKit transcript selection, SwiftData models, media services, and assets.
- `Tests/`: XCTest unit and UI suites.
- `project.yml`: XcodeGen source of truth; generated Xcode project is ignored.
- `scripts/`: local setup, testing, and CI signing import.
- `fastlane/`: signed archive and App Store Connect upload.
- `.github/workflows/`: CI and release pipelines.

The shipped app uses SwiftData and local file storage. ZIPFoundation is pinned for streamed local archive inspection; the app has no configured backend endpoint or analytics. The repository's undeployed cloud-alignment backend remains gated on its documented benchmarks. The app icon is a development placeholder; replace it before release.
