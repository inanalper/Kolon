<p align="center">
  <img src="docs/icon.png" width="128" alt="Kolon app icon">
</p>

# Kolon

**Quick Look for Apache Parquet on macOS.** Select a `.parquet` file in Finder, press <kbd>Space</kbd>, see your data — schema, types, and rows in a native table. No Python, no Java, nothing else to install.

![Kolon previewing a parquet file with Quick Look](docs/demo.gif)

## Features

- **Native table view** — looks and feels like macOS's built-in CSV preview, in both light and dark mode
- **Schema at a glance** — column names with their types (`BIGINT`, `VARCHAR`, `TIMESTAMP`, …) in the header
- **File facts in the status bar** — total rows × columns, file size, compression codec, row group count
- **Fast on big files** — powered by an embedded [DuckDB](https://duckdb.org); only the first 500 rows are read, row counts come from parquet metadata
- **Handles the ugly stuff** — NULLs shown distinctly, 300+ column files, megabyte-sized cells, corrupt files get a readable error instead of a blank panel

<p align="center">
  <img src="docs/light-mode.png" width="720" alt="Kolon preview in light mode">
</p>

## Install

### Homebrew

```bash
brew install --cask inanalper/tap/kolon
```

### Manual

Download the latest `Kolon.app` from [Releases](https://github.com/inanalper/Kolon/releases), move it to `/Applications`, and launch it once so macOS registers the Quick Look extension.

### Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone https://github.com/inanalper/Kolon && cd Kolon
./Scripts/fetch-duckdb.sh          # downloads the pinned libduckdb release
xcodegen generate
xcodebuild -project Kolon.xcodeproj -scheme Kolon -configuration Release \
           -derivedDataPath build build
cp -R build/Build/Products/Release/Kolon.app /Applications/
open /Applications/Kolon.app       # registers the extension, then you can close it
```

If a preview doesn't appear right away, restart Quick Look with `killall QuickLookUIService` or log out and back in.

## How it works

Kolon is a sandboxed Quick Look app extension with [DuckDB](https://duckdb.org) embedded as a static payload — parquet decoding, type inference, and metadata all come from DuckDB's parquet reader, rendered into an AppKit `NSTableView`. Previews are read-only and never leave your machine.

Preview limits (the status bar tells you when they kick in): first **500 rows**, first **200 columns**, cells truncated at **300 characters**.

## Roadmap

- Homebrew tap, signed & notarized releases
- More formats on the same engine: Arrow/Feather, Avro, ORC, compressed JSONL/CSV

## License

[GPL-3.0](LICENSE)
