# tidewatch

`tidewatch` is a small command-line tool for people who work around the water. It polls published tide tables for a list of harbours you care about and prints the next high and low tide for each one, so you can check the state of the tide without digging through a website or a laminated card in the wheelhouse.

It is aimed at anyone who launches a boat, times a dive, digs clams, or plans work on a mooring.

## Installation

`tidewatch` is a single Python package with no compiled dependencies.

With pip:

```
pip install tidewatch
```

With pipx, which keeps it isolated from your system Python:

```
pipx install tidewatch
```

If you live on Arch Linux, there is a package in the AUR:

```
yay -S tidewatch
```

Python 3.9 or newer is required. Run `tidewatch --version` afterwards to confirm the install worked.

## Usage

The basic form is:

```
tidewatch [harbour] [options]
```

With no harbour given, `tidewatch` checks every harbour in your configuration file (see below).

Examples:

Check the default harbours:

```
$ tidewatch
WHITBY        next high  14:32 (1.4 h)   5.8 m
WHITBY        next low   20:47 (7.6 h)   1.1 m
PORTMCLELLAN  next high  13:58 (1.1 h)   4.9 m
PORTMCLELLAN  next low   20:12 (7.0 h)   0.8 m
```

Check one harbour, wherever you are:

```
$ tidewatch oban
OBAN  next high  16:05 (2.2 h)  4.6 m
OBAN  next low   22:19 (8.4 h)  1.2 m
```

Watch mode, which redraws the display every five minutes until you stop it with Ctrl-C:

```
$ tidewatch watch --interval 300
```

Useful options:

- `--units ft` — print heights in feet instead of metres.
- `--format json` — machine-readable output for scripts.
- `--window 12h` — extend the horizon from the default 6 hours to 12.
- `--no-color` — plain output for logging or cron jobs.

## Configuration

`tidewatch` reads `~/.config/tidewatch/config.toml` (or the file named in `$TIDEWATCH_CONFIG`). A starter config is created the first time you run the tool.

```toml
timezone = "local"

[harbours]
whitby = { station = "UKHO-0342" }
oban = { station = "UKHO-0517" }

[harbours."port mclellan"]
station = "CHS-11870"
label = "PT MCLELLAN"
```

Each harbour entry maps a friendly name to a station identifier from the supported tide providers. Currently `tidewatch` can poll UK Hydrographic Office stations and Canadian Hydrographic Service stations; the station IDs are listed in the output of `tidewatch stations <provider>`.

Other settings:

- `timezone` — `"local"`, `"utc"`, or an IANA name such as `"America/Halifax"`.
- `cache_minutes` — how long downloaded tide tables stay valid on disk. Default 60. Set to 0 to always fetch fresh.
- `providers.<name>.api_key` — API keys live in this table, never in the harbour list.

## Troubleshooting

**"no harbour named X"** — The name must match a key in your config file, though matching is case-insensitive and ignores hyphens. Run `tidewatch list` to see what you have configured.

**Stale or wrong times** — Tide tables are cached under `~/.cache/tidewatch/`. If a provider has republished a correction and you are still seeing old times, run `tidewatch refresh` or set `cache_minutes = 0`.

**"station not in provider"** — Station IDs change occasionally. Confirm the ID with `tidewatch stations <provider>`. If the station was retired, remove the entry from your config.

**Network errors behind a proxy** — `tidewatch` respects the standard `HTTPS_PROXY` and `NO_PROXY` variables. Rate-limit responses are retried twice with a backoff; if you poll more than a few times an hour, register for a provider API key and set it in the config.

**Heights look wrong by a constant offset** — Some stations report heights above chart datum and others above a local datum. Check the provider's station page; `tidewatch` prints whichever datum the table uses.

**JSON output is empty** — JSON mode writes errors to stderr, not into the JSON document, so a failed fetch does not silently produce an empty array. Run without `--format json` to see the error message.

Bug reports and station requests are welcome at the project repository. When you report a problem, include the output of `tidewatch --version` and the harbour or station ID involved.
