# YouTube import

Choose **Library → + → YouTube video**, paste an HTTPS YouTube link and open it.
Play the video, enable captions in the desired language, then choose **Get subtitles**.
Review the source language and choose **Add to library**.

Alternatively, open the video in Safari, play it with captions enabled and choose
Safari **Share → Language Learner**. Confirm save, open Language Learner, then review
and add the pending video. Cancelled reviews stay pending. An import ID is inserted
only once if removing its inbox file must be retried.

The shared capture script reads player metadata, with a fallback to serialized HTML
script data, and uses the latest matching timedtext request when available. The bare
caption URL can return HTTP 200 with an empty body; enabling captions lets the player
construct its current request. Only video ID, title, language, duration and cue text/times
leave the page. Signed URLs, cookies and request tokens are not saved. This unofficial,
best-effort integration may require updates when YouTube changes. Missing captions,
live videos and failed downloads report recoverable errors; no audio is downloaded.

The reader uses the YouTube IFrame Player API in WKWebView and existing native transcript,
translation and dictionary views. Synchronization reads the media clock every 200 ms.
Internet is required for video. Cue timing is preserved; no word timing or offline phrase
audio is invented. Library backups retain their metadata-only contract: reimport source
material before restoring its saved state.

## Signing

Register/enable `group.com.rubleuskia.foreignlanguagelearner.youtube` for both the app and
YouTubeShare extension in the paid Apple developer team's provisioning profiles before a
device Release build. Simulator Debug uses this group too. Personal Team device Debug keeps
empty entitlements and supports in-app URL import; Safari shared storage needs paid-team
signing. The extension explains this if shared storage is unavailable. Project generation
does not change Apple developer-portal settings or provisioning profiles.

The inbox is bounded to 20 files. Payload validation limits file/text size, cue count and
duration, validates IDs and requires ordered finite cue intervals. The main app validates
again before inserting into SwiftData; the extension cannot access its model store.

## Verification

iPhone 17 Pro simulator / iOS 26.5: the real Safari Share Extension captured English captions
for `jNQXAC9IVRw` (six cues), wrote the App Group inbox and the main app reviewed and inserted
the item. Unit tests check URL hosts and invalid timing/highlighting across cue gaps.
Video playback to completion and cue highlighting were verified in the native reader.
All 283 iOS unit tests, four JavaScript extractor tests and 31 CI tests passed. Unsigned
device Release compilation passed. The first in-app URL attempt exposed missing resource
timing history; the importer now observes successful caption requests from document start.
After reopening the video in the final installed build, in-app URL import captured all six
English cues without inspector commands, presented language review and inserted a new
library item. Both Safari Share and in-app URL flows are verified for this sample.
Paid-team device signing and broad video/language coverage need separate acceptance.
