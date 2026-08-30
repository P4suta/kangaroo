# Kangaroo release checklist

This is the maintainer runbook for the first public release. Stop if any gate
is incomplete. Pull requests and CI may prepare artifacts, but only a reviewed
commit on `main` may be tagged or published.

## Before merging 1.0.0

1. Confirm every required check on PR #12 is green, every review thread is
   resolved, and an external maintainer has approved the exact head commit.
2. Confirm the final review log contains at least three complete critical
   reviews and two consecutive reviews that began with no new P0 or P1 issue.
3. Close obsolete PR #11 without merging it.
4. Verify the repository description, homepage, topics, default branch, branch
   protection, and release-tag rules. Confirm that the `release` environment
   requires the intended reviewers.
5. Confirm the `release` environment can read secrets named `HEXPM_API_KEY`,
   `VSCE_PAT`, and `OVSX_PAT`. Check names and access only; never print secret
   values into a terminal or workflow log.
6. Confirm the Hex account can publish `kangaroo`, the VS Code publisher is
   `yasunobu`, and the matching Open VSX namespace is available.
7. Merge PR #12 only after all of the preceding checks remain true. Record the
   exact merge commit. Do not tag a pull-request head or a moving branch name.

## Bootstrap v1.0.0

The repository manifest already records 1.0.0. The release workflow therefore
waits until tag `v1.0.0` exists before enabling release-please on later pushes;
this prevents the merge push from racing ahead to a post-1.0 release.

1. Prepare reviewed release notes from the 1.0.0 section of `CHANGELOG.md`.
2. Create a draft GitHub Release named `Kangaroo 1.0.0`, with tag `v1.0.0`
   targeting the exact merge commit recorded above.
3. Verify the draft's target and notes, then publish it. The `release.published`
   event builds the Hex tarball and VSIX once, verifies the clean-install and
   offline lifecycle, and starts the GitHub, Hex, VS Code Marketplace, and Open
   VSX publication jobs from that shared artifact.
4. Do not regenerate, substitute, or upload a locally exported Hex tarball.
   The exact workflow artifact is the package that all later checks identify.

Future versions use the release-please pull request and GitHub Release it
creates after `v1.0.0` has been bootstrapped.

## Verification and safe retries

1. Verify the GitHub Release contains the versioned Hex tarball, VSIX, protocol
   schema, changelog, and `checksums.txt`; run the checksum verification after
   downloading all five files into a clean directory.
2. Verify the bytes served for Hex `kangaroo` 1.0.0 match the GitHub tarball,
   verify that the matching HexDocs site is available, then install that
   released version in a fresh consumer and exercise `init`, one-shot, watch,
   coverage, doctor, and daemon, including an offline run after dependencies
   have been fetched once.
3. Install the published VSIX through the VS Code Marketplace and verify the
   Open VSX listing. Run the Neovim headless smoke test against the tagged
   package as well.
4. If one destination fails, use `workflow_dispatch` for tag `v1.0.0` and set
   `target` to only `github`, `hex`, `vscode`, or `open-vsx`. `build` rebuilds
   and validates a separately named artifact without publishing; it never
   replaces or supplies bytes to a publication retry. `all` retries every
   destination.
5. A publication retry first restores all five checksummed files from the
   GitHub Release, then falls back to the original unexpired canonical Actions
   artifact when the Release is incomplete. It does not build package bytes.
   If neither exact source is available, the workflow fails closed; recover the
   reviewed artifact through maintainer review instead of regenerating it.
6. Hex succeeds only when an existing package is byte-for-byte identical; a
   different existing tarball is a hard failure that requires investigation.
7. The GitHub job treats an existing asset as success only when its bytes match
   the canonical artifact. It uploads missing assets and refuses to overwrite a
   same-named asset with different bytes.
