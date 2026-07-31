# The Homebrew tap

`Casks/menudock.rb` here is the master copy of the cask. It is **not** what Homebrew reads —
Homebrew reads `bebarebears/homebrew-tap`, a separate repository. This copy lives here so the
cask is versioned alongside the app it installs.

The tap is live at
[bebarebears/homebrew-tap](https://github.com/bebarebears/homebrew-tap) — the `homebrew-`
prefix is what makes `brew tap bebarebears/tap` resolve, and users never type it.

## Publishing a new version by hand

Only needed while `TAP_TOKEN` is unset; see below for the automatic route.

```bash
git clone https://github.com/bebarebears/homebrew-tap.git
cp homebrew/Casks/menudock.rb homebrew-tap/Casks/
# update version + sha256 to match the release, then commit and push
```

The `sha256` is printed by `Scripts/make-dmg.sh` and included in every release's notes.
To check a change before anyone else gets it:

```bash
brew update && brew info --cask bebarebears/tap/menudock
brew fetch --cask bebarebears/tap/menudock   # downloads and verifies the checksum,
                                             # without installing anything
```

## Keeping it up to date automatically

Add a repository secret named **`TAP_TOKEN`** to the MenuDock repo — a fine-grained personal
access token with **Contents: read and write** on `bebarebears/homebrew-tap`. The release
workflow then rewrites `version` and `sha256` and pushes on every tag, and users get the new
build with `brew upgrade`.

Without the secret that job is skipped, and the cask has to be bumped by hand.

## Why `--no-quarantine`

Homebrew quarantines downloaded apps by default, which for an app without a paid Developer ID
certificate means Gatekeeper blocks the first launch. The flag skips that, which is the whole
reason the Homebrew path is nicer than downloading the DMG. Users who leave the flag off get
the same one-time "Open Anyway" step described in the README.

## Getting into homebrew-cask proper

The official `homebrew/cask` repository has notability requirements — roughly 75 stars, forks
or watchers, plus a stable release history. Once MenuDock clears that bar it can be submitted
there, and `brew install --cask menudock` works with no tap at all. Until then the tap is the
supported route.
