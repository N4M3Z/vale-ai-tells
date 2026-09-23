# tidewatch

tidewatch polls tide tables for a list of harbours and prints the next high tide and the next low tide. It is the check you run before you leave the quay.

The program does not compute predictions. It reads your harbour list, fetches the published table for each station, and prints the two events that are still ahead. Times use the harbour zone unless you set another zone.

## Installation

Install the binary that matches your system. Releases are archives plus a checksum file. Verify the archive before you install it.

Linux, x86_64:

```
curl -fsSL -O https://example.com/tidewatch/tidewatch-1.4.0-linux-x86_64.tar.gz
curl -fsSL -O https://example.com/tidewatch/tidewatch-1.4.0-SHA256SUMS
sha256sum -c tidewatch-1.4.0-SHA256SUMS
tar -xzf tidewatch-1.4.0-linux-x86_64.tar.gz
sudo install -m 755 tidewatch /usr/local/bin/tidewatch
```

macOS, with Homebrew:

```
brew install tidewatch/tap/tidewatch
```

Check the install with `tidewatch version`. A user file at `~/.config/tidewatch/config.toml` overrides `/etc/tidewatch/config.toml`.

## Usage

Poll every harbour in the config and print the next high and the next low:

```
tidewatch
```

```
plymouth    high  14:22  5.1 m    low  20:41  0.6 m
falmouth    high  14:48  4.8 m    low  21:06  0.7 m
st-marys    high  15:05  5.0 m    low  21:19  0.8 m
```

Heights are metres above chart datum. A star beside a time means the event falls inside the next 30 minutes.

Print one harbour. The argument is the `name` key from the config, not the label on a chart:

```
tidewatch show plymouth
```

```
plymouth (Devonport)
  next high   Thu 14:22 BST   5.1 m
  next low    Thu 20:41 BST   0.6 m
  source      ukho  fetched 2026-09-22 08:10 UTC
```

Refresh one harbour on a timer:

```
tidewatch watch --harbour falmouth --interval 15m
```

`Ctrl-C` stops the watch. Add `--json` to any of these commands when a script reads the output. Each record has `harbour`, `event`, `time`, `height_m`, and `fetched_at`.

`tidewatch list` shows the configured harbours and their station ids. `tidewatch refresh` skips the cache and fetches again.

## Configuration

The config format is TOML. tidewatch loads `~/.config/tidewatch/config.toml`. A `tidewatch.toml` file in the current directory overrides keys that it sets. `TIDEWATCH_CONFIG` selects another path.

```
poll_interval = "30m"
cache_ttl = "2h"
timezone = "harbour"
units = "metres"

[[harbours]]
    name = "plymouth"
    station = "ukho:ply-01"
    label = "Devonport"

[[harbours]]
    name = "falmouth"
    station = "ukho:fal-01"
    label = "Falmouth"

[[harbours]]
    name = "st-marys"
    station = "ukho:stm-01"
    label = "St Mary's"
```

`poll_interval` is the pause between fetches in `watch`. The default is 30 minutes. `cache_ttl` is how long a normal run reuses a table. The default is 2 hours.

`timezone` takes `harbour`, `utc`, or an IANA name such as `Europe/London`. `units` takes `metres` or `feet`.

`station` is `provider:id`. Built-in providers are `ukho`, `noaa`, and `shom`. The id is that provider's station code. A wrong code is the usual cause of an empty tide.

If a provider requires a key, set `TIDEWATCH_PROVIDER_KEY` in the environment. tidewatch reads the variable at startup. The key stays in the environment.

## Troubleshooting

**The shell cannot find the command.** The install directory is not on `PATH`. Run `command -v tidewatch`. If the result is empty, open a new shell.

**`unknown harbour`.** The name does not match a `name` key. Run `tidewatch list` and copy the key. The match is case sensitive.

**`station returned no events`.** The station id is wrong, or the provider has no rows for the next 48 hours. Compare the id with the provider catalogue. Many secondary ports have no table. Use the standard port from the sailing directions.

**Times are an hour off.** With `timezone = "harbour"`, each station uses the zone published with its table. A fixed IANA name puts every harbour in that one zone. The difference appears at the BST and GMT change.

**`rate limited`, or the fetched time is old.** A loop is calling `tidewatch refresh` too often. Normal runs should honour `cache_ttl`. After HTTP 429, tidewatch waits 10 minutes and serves the last good table.

**No output, exit code 0.** The harbour list is empty. An empty list is valid TOML and still exits 0. Add at least one `[[harbours]]` entry.

**Checksum failed during install.** Do not run that binary. Download the archive and the checksum file again. A mismatch means the download is not the release file.

Exit status is 0 on success, 1 for a bad argument or an unknown harbour, 2 for a config error, and 3 when the provider failed and no cached table is left.
