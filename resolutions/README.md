# Recorded merge resolutions

`scripts/merge_prs.sh` merges PRs in the order given. When two of them change the same lines of `lib/`, git cannot
merge them alone; a resolution recorded here, in git rerere's format (`<repo name>/<conflict id>/preimage` and
`postimage`), is applied instead. It only matches the same conflict, so it is tied to the merge order.

| Resolution | PRs, in order | What it keeps |
|---|---|---|
| `Xcodeproj/a4cf2944…` | Xcodeproj #1059, then #1062 | #1059 moves `to_hash_as` and friends out of `PBXNativeTarget`; #1062's `remove_from_project` is added after them |
| `Xcodeproj/0fdf3e8b…` | Xcodeproj #1027, then #1029 | the build phase exception set's `display_name` with both: `'Resources'` for a Resources phase (#1029), else the phase's name, else its UUID (#1027) |

To record one: run `scripts/merge_prs.sh` until it stops on the conflict, merge that PR by hand in the clone with
`git -c rerere.enabled=true merge`, resolve, commit, and copy the new `preimage` and `postimage` from the clone's
`rr-cache/<id>/` (rename `*.N` variants to the plain names) to `resolutions/<repo name>/<id>/`.

Two PRs that implement the same thing differently are not resolved here: Xcodeproj #1051 and #1057 both add
`dstSubfolder`, with different names (Xcode writes `Product` and `None`, as #1057 does), so list only one of them.
