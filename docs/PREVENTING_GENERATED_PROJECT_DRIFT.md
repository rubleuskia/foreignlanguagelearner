# Preventing Generated Xcode Project Drift

This project uses XcodeGen. The checked-in `project.yml` is the source of truth; `ForeignLanguageLearner.xcodeproj` is generated locally and intentionally ignored by Git.

## What happened

`App/Models/SelectionTranslationPreview.swift` existed in the repository and was referenced by several Swift files, but the local generated Xcode project had been created before that file was added. Because the stale project did not list the file in the app target's Sources build phase, the compiler reported:

```text
Cannot find type 'SelectionTranslationPreview' in scope
```

This error can look like a Swift visibility or module problem even when the declaration itself is correct. For this repository, first verify that the source file is included in the generated target.

## Required development workflow

Run commands from the repository root. Regenerate after adding, moving, or deleting files under `App/` or `Tests/`, changing `project.yml`, or updating the checkout through a pull, merge, rebase, or branch switch:

```sh
bash scripts/bootstrap.sh
```

Then build or test from the regenerated project:

```sh
xcodebuild build \
  -project ForeignLanguageLearner.xcodeproj \
  -scheme ForeignLanguageLearner \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO
```

For unit and UI tests, run `bash scripts/test.sh`; it already calls `scripts/bootstrap.sh`, so a separate regeneration is unnecessary for that path. Building or testing directly in Xcode does not invoke the bootstrap script. If Xcode still shows the old file list after regeneration, close and reopen the project.

Do not edit `ForeignLanguageLearner.xcodeproj` by hand. Persist project structure and build-setting changes in `project.yml`, then regenerate.

## Fast diagnosis for “cannot find type” errors

Use this sequence before changing Swift access control or imports:

1. Confirm the declaration exists and is tracked:

   ```sh
   rg -n '\b(struct|class|enum|protocol|typealias)\s+TypeName\b' App Tests
   git ls-files --error-unmatch path/to/TypeName.swift
   ```

2. Regenerate the project:

   ```sh
   bash scripts/bootstrap.sh
   ```

3. Confirm the generated project contains the file and its Sources build-file entry:

   ```sh
   rg -n -F 'TypeName.swift' ForeignLanguageLearner.xcodeproj/project.pbxproj
   ```

4. Build again. Only if the regenerated project still fails should you investigate module imports, access levels, target membership, conditional compilation, or a genuine type-checking error.

## Guardrails that prevent recurrence

- Keep `project.yml` as the only project-definition file that developers modify.
- Run `scripts/bootstrap.sh` before opening the project after a branch switch or merge.
- Run `scripts/test.sh` before submitting changes that add or move source files. It regenerates the project as its first project-specific step.
- Generate before the first build/test in each CI job, and regenerate if the source tree or specification changes afterward. Current CI runs `scripts/test.sh` (which generates first), then reuses that project for its Release build. Publishing explicitly calls `scripts/bootstrap.sh` before its build.
- Treat a missing-type error involving a recently added file as a generated-project check first, especially when the file is under a directory already covered by the `sources` entries in `project.yml`.

## Optional local sanity check

When debugging project-generation issues, compare the source tree with the generated project after regeneration:

```sh
rg --files App Tests -g '*.swift' | sort
rg -n "\.swift in Sources" ForeignLanguageLearner.xcodeproj/project.pbxproj
```

The generated project should include every app and test Swift file in the appropriate target, subject to intentional exclusions in `project.yml`. These commands are a manual sanity check, not an automated target-membership test. Since the project is intentionally ignored, regeneration alone should not add tracked changes to Git status; any existing changes remain.

## Handling merge conflicts and concurrent edits

Before merging or regenerating, inspect local changes and unresolved conflicts:

```sh
git status --short
git diff --name-only --diff-filter=U
git ls-files -u
```

Resolve conflicts in tracked Swift files and `project.yml` first. Preserve required source paths, exclusions, dependencies, and settings from both changes according to the intended result; choosing an entire side can silently omit needed configuration. If a conflict needs a product decision, settle it before continuing the merge.

Do not attempt to merge the generated `.xcodeproj` or force-add it to Git. Once tracked conflicts are resolved, regenerate it from the resolved specification and source tree, then build and test. Regeneration repairs target membership; it does not resolve Swift source conflicts.

Before regeneration, move any intentional settings edited only in Xcode into `project.yml`, because generation may overwrite those project edits. Preserve unrelated local changes and editor state (such as `docs/.obsidian/`); do not delete them to obtain a clean status. Avoid concurrent project generation, source moves, or branch switches while a build is running.

## Scope of this fix

The corrective action for this incident was to regenerate the project with `bash scripts/bootstrap.sh`; no Swift source change was required. If regeneration exposes unrelated compiler or simulator-service errors, record those separately rather than masking them with source edits.
