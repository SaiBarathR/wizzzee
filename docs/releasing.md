# Releasing

Releases are built and published by GitHub Actions from a tag. Nothing is
uploaded from a developer machine, and the workflow refuses to overwrite an
existing release or asset.

## What a release contains

| Asset | Contents |
| --- | --- |
| `Wizzzee-<version>-macos-universal.zip` | The `.app`, universal (`arm64` + `x86_64`), ad-hoc signed |
| `SHA256SUMS.txt` | Checksum of the archive |

## Steps

1. **Bump the version.** Edit `CFBundleShortVersionString` in
   `Resources/Info.plist` to the new `MAJOR.MINOR.PATCH`, and increment
   `CFBundleVersion` by one. The UI and `--version` read these, so nothing else
   needs editing.

2. **Write the release notes** at `docs/releases/v<version>.md`. The workflow
   publishes this file verbatim as the release body, so it needs to stand on its
   own for someone who has never seen the repository.

3. **Check locally** before tagging:

   ```bash
   ./scripts/validate-release.sh v0.1.0
   ```

   It prints the version on success, and otherwise explains what disagrees — a
   malformed tag, a version that does not match the bundle, a non-integer build
   number, or missing release notes.

4. **Dry-run the packaging** (optional but cheap). Run the *Release macOS app*
   workflow with `workflow_dispatch`, giving the intended tag and the ref to
   package. It builds, verifies and uploads the assets as a workflow artifact
   without publishing anything.

5. **Commit, tag, and push.**

   ```bash
   git tag -a v0.1.0 -m "Wizzzee 0.1.0"
   git push origin main --follow-tags
   ```

6. **Watch the run.** Pushing a `v*` tag triggers build, verification and
   publication.

   ```bash
   gh run watch
   ```

## What the workflow verifies

Before anything is published:

- the tag, the bundle version and the release notes all agree
- `swift build` succeeds
- `--selftest` passes every check, including the destructive delete paths
- the bundle contains both `arm64` and `x86_64` slices
- the icon is present and non-empty
- the ad-hoc signature verifies with `--deep --strict`

Then, after archiving, it extracts the zip into a clean directory and re-checks
the checksum, the version, the architectures, the icon and the signature on the
extracted copy — so what gets uploaded is what was verified, not merely what was
built.

## Signing

Wizzzee is ad-hoc signed, not Developer ID signed and not notarized: a real
signature needs a paid Apple Developer account. Two consequences worth
remembering:

- **Users get a Gatekeeper prompt** on first launch and have to approve the app
  under **Open Anyway** in System Settings → Privacy & Security. Control-click →
  **Open** still works on macOS 14, but macOS 15 removed that shortcut for apps
  that aren't notarized, so release notes should point at Open Anyway.
- **Full Disk Access is tied to the exact binary.** macOS keys the grant on the
  code signature, and an ad-hoc signature changes with the binary, so a new
  release has to be added to Full Disk Access again. Release notes should say
  so.
