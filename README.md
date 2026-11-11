# xcodeproj-corpus-check

Checks [Xcodeproj](https://github.com/CocoaPods/Xcodeproj) against real Xcode projects, using Xcode as the judge.

For each project in `corpus.tsv` (public `project.pbxproj` files found by GitHub code search, fetched by blob SHA), in throwaway copies:

| Check | Passes when |
|---|---|
| `pbx-<lib>` | After Xcodeproj opens and saves the project, `xcodebuild -list -json` and `-showBuildSettings -json -alltargets` report the same as before |
| `edit-<lib>` | After setting `CURRENT_PROJECT_VERSION=4242`, only settings that now contain 4242 changed |
| `json` | Xcode 27.2 converts the project to `project.xcproj`; Xcodeproj with JSON support opens and saves it; Xcode reports the same |
| `cross` | Xcode's JSON conversion of the Xcodeproj-saved project equals its conversion of the original |

Nothing is built, so no project's build scripts run. Resolving Swift packages downloads them and evaluates their `Package.swift`, which is why it only happens here, on a disposable runner (`ALLOW_PACKAGES=1`).

Run: Actions → Corpus check → Run workflow. Results are uploaded as artifacts; `ruby scripts/summary.rb <folder>` prints the counts.

Locally, without packages: `ruby scripts/fetch.rb corpus.tsv corpus`, then `ruby scripts/judge.rb "$PWD/corpus" "$PWD/out" '{"master":"<lib>","1057":"<lib>"}' 4`.
