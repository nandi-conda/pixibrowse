# pixibrowse

A desktop and web GUI for browsing conda package metadata, ported from
[pixi-browse](https://github.com/pavelzw/pixi-browse), the terminal UI by
Pavel Zwerschke. Browse packages, versions, dependencies and files of any
conda channel, without a terminal.

The interface is built with [flatkit](https://github.com/codegod100/flutterkit):
flat widgets with no ripples, fades or sliding, which follow the KDE Plasma
colour scheme on Plasma and the desktop's light or dark mode elsewhere.
Package summaries, summary search and the disk cache come from
[zumba](https://github.com/codegod100/zumba).

## Features

- **Search every channel** on prefix.dev at once, the way its website does,
  with no channels to add first. Each hit names its channel, and opening one
  reads that channel's repodata directly. This is the default unless `-c` is
  given; `a` (or the *All channels* box) switches to browsing chosen
  channels.
- **Browse packages** from any conda channel (conda-forge, bioconda, a URL…),
  several channels at once.
- **Package summaries** from the channel's `channeldata.json`, shown next to
  each name and loaded in the background so the list never waits for them.
- **Substring search** over thousands of packages, ranked like pixi-browse
  (earliest match, then shortest name), then packages whose summary or
  description mentions the query, marked as such. Plus filters for a
  package's versions, dependencies and files.
- **Package overview** before you pick an artifact: summary, description,
  licence, latest version, platforms, versions and links, with no download.
- **Versions grouped by platform**, in collapsible sections sorted newest first
  using conda's version ordering.
- **Detailed metadata**: license, checksums, build info, timestamps, size,
  links to the repository, docs, homepage, recipe maintainers and the feedstock
  commit it was built from.
- **Dependencies, constraints, extra dependencies and run exports.**
- **Package contents**: the file list from `info/paths.json` (sizes, symlinks,
  prefix placeholders) and every file under `info/`, including `about.json` and
  the rendered recipe, read straight from the artifact.
- **Repodata patches**: diff the artifact's own `info/index.json` against the
  record the channel serves.
- **Download** artifacts, copy their URLs, or copy a package or record as
  JSON.
- **Disk cache** of shard indexes, shards and channeldata, revalidated with
  ETags after an hour and used offline; `r` refreshes everything.
- **Platform selector** with the platforms the channels actually serve.
- **Vim-style keyboard navigation**, as in the TUI.
- **No animations** on dialogs, menus, tabs or page changes.

## Install

On Linux, install it with pixi from the nandi-testing channel on prefix.dev,
which also carries the conda-forge packages it needs:

```bash
pixi global install -c https://prefix.dev/nandi-testing pixibrowse
```

Or grab the AppImage from the rolling
[latest release](https://github.com/nandi-conda/pixibrowse/releases/tag/latest),
`chmod +x` it and run it; it can update itself with AppImageUpdate.

## Running

```bash
flutter pub get
flutter run -d linux     # or macos, windows
flutter run -d chrome    # web
```

Desktop builds accept the TUI's startup flags:

```bash
build/linux/x64/release/bundle/pixibrowse -c conda-forge -c bioconda -p linux-64
```

| Option             | Description                               |
| ------------------ | ----------------------------------------- |
| `-c`, `--channel`  | Channels to browse (repeat for several)   |
| `-p`, `--platform` | Platforms to include (repeat for several) |

Channel names resolve to `https://conda.anaconda.org/<name>`; full URLs are
used as they are. On the web the channel has to allow cross-origin requests,
which `conda.anaconda.org` does.

The cache lives in `~/.cache/pixibrowse` (`$XDG_CACHE_HOME/pixibrowse`,
`~/Library/Caches/pixibrowse` on macOS, `%LOCALAPPDATA%\pixibrowse\cache` on
Windows), or `$PIXIBROWSE_CACHE_DIR`. The web app relies on the browser's
HTTP cache instead.

Searching all channels uses prefix.dev's public GraphQL API
(`https://prefix.dev/api/graphql`), which needs no key. Picking channels
with `c` switches to browsing them. Channels picked with `c` are remembered for the next start, in
`~/.config/pixibrowse/channels.json` (`$XDG_CONFIG_HOME/pixibrowse`,
`~/Library/Application Support/pixibrowse` on macOS, `%APPDATA%\pixibrowse`
on Windows, or `$PIXIBROWSE_CONFIG_DIR`), and in `localStorage` on the web.
Channels given with `-c` are browsed for that run without replacing them.

Build the web app with its rendering engine bundled, rather than loaded from
Google's CDN:

```bash
flutter build web --release --no-web-resources-cdn
```

## Keybindings

| Key       | Action                                 |
| --------- | -------------------------------------- |
| `j` / `k` | Move selection down / up               |
| `h` / `l` | Focus left / right pane                |
| `gg` / `G` | Jump to top / bottom                  |
| `Ctrl+u` / `Ctrl+d` | Page up / down               |
| `Enter`   | Open / select (or fold a platform)     |
| `Esc`     | Back, or leave the search field        |
| `/`       | Search packages or versions            |
| `s`       | Toggle searching summaries             |
| `r`       | Refresh, skipping the cache            |
| `y`       | Copy the package or artifact as JSON   |
| `c`       | Select channels                        |
| `p`       | Select platforms                       |
| `d`       | Download the selected artifact         |
| `1`–`5`   | Metadata, Dependencies, Files, About, Patches |
| `?`       | Show help                              |

## How it works

Like pixi-browse, the app reads
[sharded repodata (CEP 16)](https://github.com/conda/ceps/blob/main/cep-0016.md):
a small index of package names per platform, then one shard per package on
demand. Channels without shards fall back to `repodata.json(.zst)`. Package
summaries come from `channeldata.json` (about 23 MB for conda-forge), which is
optional: channels without it just show bare names.

Shards and `.conda` archive members are zstd-compressed MessagePack and tar.
The Dart zstd packages either wrap the native library (no web) or rely on
64-bit integers (wrong when compiled to JavaScript), so
[`lib/src/codec/zstd.dart`](lib/src/codec/zstd.dart) is a small RFC 8878
decoder that keeps every value under 32 bits and runs unchanged on desktop and
web; [`lib/src/codec/msgpack.dart`](lib/src/codec/msgpack.dart) does the same for
MessagePack. Package contents come from the archive's `info/` section only, so
the payload of a `.conda` file is never decompressed.

Not ported from the TUI: MatchSpec and who-needs queries, Sigstore attestation
verification, side-by-side artifact comparison, and pixi configuration files
(mirrors, authentication). Not ported from zumba: its prefix.dev GraphQL
lookup.

## Development

```bash
flutter analyze
flutter test
```

The tests decode a real conda-forge shard and `.conda` info section
(`test/fixtures/`) and drive the whole UI against a fake channel.

## License

BSD 3-Clause, like pixi-browse. See [LICENSE](LICENSE).

## Icon

The source icon is `assets/icon/pixibrowse.svg`; the web, macOS, Windows and Linux
icons are rendered from it. On Linux the bundle sets its own window icon; for a
launcher entry and the Wayland icon, install `linux/dev.codegod.pixibrowse.desktop`
to `~/.local/share/applications/` and `linux/dev.codegod.pixibrowse.svg` to
`~/.local/share/icons/hicolor/scalable/apps/`.
