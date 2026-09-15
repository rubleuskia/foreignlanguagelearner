# Release setup

## One-time Apple setup

1. Enroll in the Apple Developer Program.
2. Register the final explicit bundle identifier and create its App Store Connect app record. Update `PRODUCT_BUNDLE_IDENTIFIER` in `project.yml` (and the test identifiers).
3. Create an Apple Distribution certificate with its private key, export it as a password-protected `.p12`, and create an App Store distribution provisioning profile for that certificate and identifier.
4. Create a team App Store Connect API key with access to the app and permission to upload builds (App Manager is suitable for both lanes). Record its key ID and issuer ID and download the `.p8` once.

## GitHub setup

In repository Settings → Environments, create **app-store**. Restrict deployment branches to `main` and configure required reviewers where your GitHub plan supports them.

Environment variables:

| Variable | Value |
| --- | --- |
| `APP_IDENTIFIER` | Registered bundle identifier |
| `APPLE_TEAM_ID` | Apple Developer team ID |

Environment secrets:

| Secret | Value |
| --- | --- |
| `IOS_CERTIFICATE_BASE64` | Base64-encoded distribution `.p12`, including private key |
| `IOS_CERTIFICATE_PASSWORD` | Password for that `.p12` |
| `IOS_PROFILE_BASE64` | Base64-encoded App Store `.mobileprovision` |
| `ASC_KEY_ID` | App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_KEY_CONTENT` | Base64-encoded API key `.p8` |

On macOS, `base64 -i /path/to/file | pbcopy` copies an encoded file without printing it. Paste directly into the matching GitHub secret. Never commit credentials. Rotate certificates/profiles before expiry. The workflow uses an ephemeral keychain and removes signing files in an always-run cleanup step on a disposable hosted runner.

Enable GitHub Actions, then configure a `main` branch ruleset requiring pull requests and the **Build and test** CI check after its first run. Workflow files alone cannot create repository settings or Apple credentials.

## Publish

1. Merge the app changes to `main`. Replace the placeholder icon and verify on a physical device. Complete App Store metadata, screenshots, privacy disclosures, age rating, and export compliance as appropriate for the actual app.
2. In Actions → **Publish iOS** → Run workflow, select `main`, version `X.Y.Z`, and `testflight` or `app-store`.
3. Tests must pass before the deployment environment is entered. Approve the environment deployment if reviewers are configured.
4. The workflow sets the marketing version from your input and uses `run_number.run_attempt` as the build number, signs an archive, and uploads it. Keep build numbers increasing if you also upload outside this workflow.
5. For TestFlight, wait for Apple processing and resolve any compliance prompts, then select tester groups in App Store Connect. Upload does not automatically distribute to external testers.
6. For App Store, the lane uploads a binary and prepares the version without submitting for review or releasing it. Finish the listing and select/submit the build in App Store Connect.

Download IPA/dSYM artifacts within seven days; preserve dSYMs in long-term release storage for production crash symbolication. Test results are retained for fourteen days. A successful upload does not guarantee Apple processing or review acceptance.

## Tooling and troubleshooting

CI selects Xcode 26.3 on `macos-15` explicitly. Update both workflow files together as hosted runner images and Apple's upload requirements change. XcodeGen is installed via Homebrew (minimum 2.45); Fastlane is pinned to 2.238.0, with transitive gems resolved at installation. For fully locked toolchains, add a Bundler lockfile and pin the project generator once a full Xcode environment is available.

- `xcodebuild requires Xcode`: install full Xcode and select its developer directory.
- No simulator: install an iOS runtime through Xcode Settings.
- Signing failure: check team, bundle identifier, profile expiry, certificate/private key, and App Store distribution profile type.
- Upload failure: check API key permissions, app record, version/build uniqueness, icon, and Apple's current SDK requirements.

References: [XcodeGen project specification](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md), [GitHub macOS runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md), [Fastlane build](https://docs.fastlane.tools/actions/build_app/), [TestFlight upload](https://docs.fastlane.tools/actions/upload_to_testflight/), [App Store upload](https://docs.fastlane.tools/actions/upload_to_app_store/).
