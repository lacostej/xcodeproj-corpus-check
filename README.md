# xcodeproj-corpus-check

Checks [Xcodeproj](https://github.com/CocoaPods/Xcodeproj) against real Xcode projects, using Xcode as the judge.

For each project in `corpus.tsv` (public `project.pbxproj` files found by GitHub code search, fetched by blob SHA), in throwaway copies:

| Check | Passes when |
|---|---|
| `pbx-<lib>` | After Xcodeproj opens and saves the project, `xcodebuild -list -json` and `-showBuildSettings -json -alltargets` report the same as before |
| `edit-<lib>` | After setting `CURRENT_PROJECT_VERSION=4242`, only settings that now contain 4242 changed |
| `json` | Xcode 27.2 converts the project to `project.xcproj`; Xcodeproj with JSON support opens and saves it; Xcode reports the same |
| `cross-<lib>` | Xcode's JSON conversion of the project saved by `<lib>` equals its conversion of the original. This also sees build phases, which `-list` and `-showBuildSettings` do not |

Nothing is built, so no project's build scripts run. Resolving Swift packages downloads them and evaluates their `Package.swift`, which is why it only happens here, on a disposable runner (`ALLOW_PACKAGES=1`).

`<lib>` is one label per Xcodeproj and Nanaimo combination:

| Label | Xcodeproj | Nanaimo | When |
|---|---|---|---|
| `master` | master | released | listed in `labels` |
| `nanaimo` | master | master + `nanaimo_prs` merged | listed, and `nanaimo_prs` is set |
| `xcodeproj` | master + `xcodeproj_prs` merged | released | listed, and `xcodeproj_prs` is set |
| `all` | master + `xcodeproj_prs` merged | master + `nanaimo_prs` merged | listed, and both are set |

`labels` defaults to `master all`. When `all` has a problem, the summary prints a `projects` expression for those projects: rerun them with `labels: nanaimo xcodeproj` to see whether the Xcodeproj or the Nanaimo side causes it.

`json_lib` names the label that runs the `json` check (default `all`; it needs a JSON-capable Xcodeproj, such as #1057 in `xcodeproj_prs`). PRs are merged by `scripts/merge_prs.sh`, in the order listed; see [resolutions/](resolutions/README.md) for conflicts.

Run: Actions → Corpus check → Run workflow. `projects` (a regular expression on project names) limits a run to some projects, e.g. to recheck the ones a fix is for. Results are uploaded as artifacts: one JSON file per project under `_results/`, with each check's verdict, error lines and duration, and the full output of every failing step under `_logs/`. `ruby scripts/summary.rb <folder>` prints the counts and the time spent per check.

Locally, without packages: `ruby scripts/fetch.rb corpus.tsv corpus`, then `ruby scripts/judge.rb "$PWD/corpus" "$PWD/out" '{"master":"<lib>","xcodeproj":"<lib>"}' 4`. A lib may be several load paths joined with `:`, e.g. `"<nanaimo>/lib:<xcodeproj>/lib"`.
