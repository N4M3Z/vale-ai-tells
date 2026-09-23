# tidewatch

`tidewatch` polls tide tables for a list of harbours and prints the next high and low tide for each one. It reads a harbour list from a config file, queries the tide provider on a schedule, and writes the results to the terminal in a compact table. Use it on a wall-mounted display, in a cron job, or from a shell prompt before you leave for the water.

## Prerequisites

- Python 3.10 or newer.
- An API key from your tide data provider. tidewatch supports NOAA and WorldTides.
- Network access to the provider API.

## Installation

Install from PyPI with pip:

```bash
pip install tidewatch
```

Or install from source:

```bash
git clone https://github.com/example/tidewatch.git
cd tidewatch
pip install .
```

Verify the install:

```bash
tidewatch --version
```

## Usage

Run tidewatch with the default config file at `~/.config/tidewatch/config.toml`:

```bash
tidewatch
```

### Example: poll once and print a table

```bash
tidewatch once
```

Output:

```
Harbour          Next high        Next low
Plymouth         14:22  (4.8 m)   20:41  (1.1 m)
Falmouth         14:05  (4.5 m)   20:18  (0.9 m)
Dartmouth        14:51  (4.2 m)   21:03  (1.3 m)
```

### Example: watch mode with a refresh interval

```bash
tidewatch watch --interval 300
```

This redraws the table every 300 seconds. Press `q` to quit. Watch mode clears the screen between redraws, so it suits a dedicated terminal or status display.

### Example: filter to one harbour and print machine-readable output

```bash
tidewatch once --harbour falmouth --format json
```

Output:

```json
{
  "harbour": "falmouth",
  "next_high": {"time": "2026-09-22T14:05:00+01:00", "height_m": 4.5},
  "next_low":  {"time": "2026-09-22T20:18:00+01:00", "height_m": 0.9}
}
```

Use `--format csv` for spreadsheet import. Combine filters with a comma: `--harbour falmouth,plymouth`.

## Configuration

tidewatch reads a TOML file. The default path is `~/.config/tidewatch/config.toml`. Override it with `--config /path/to/file.toml`.

A minimal config:

```toml
provider = "noaa"
api_key = "your-key-here"
timezone = "Europe/London"

[[harbour]]
name = "Plymouth"
station_id = "0440"

[[harbour]]
name = "Falmouth"
station_id = "0435"
```

Options:

| Key | Default | Description |
|---|---|---|
| `provider` | `noaa` | Tide data source: `noaa` or `worldtides`. |
| `api_key` | none | Provider API key. Required for WorldTides. |
| `timezone` | system | IANA name for printed times. |
| `units` | `metric` | `metric` for metres, `imperial` for feet. |
| `cache_ttl` | `900` | Seconds to reuse a fetched tide table. |
| `[[harbour]]` | none | One block per harbour, with `name` and `station_id`. |

You can set the API key in the `TIDEWATCH_API_KEY` environment variable instead of the config file. The environment variable wins when both are set.

Station IDs come from the provider. List the stations a provider knows about:

```bash
tidewatch stations --search falmouth
```

## Troubleshooting

**`error: no harbours configured`**
The config file has no `[[harbour]]` blocks, or tidewatch read a different file than you expect. Run `tidewatch once --config /path/to/config.toml` to confirm the path. Run `tidewatch doctor` to print the resolved config path and the parsed harbour list.

**`error: authentication failed (401)`**
The API key is missing or wrong. Check `TIDEWATCH_API_KEY` and the `api_key` value in the config. WorldTides keys expire after a year; request a new one from the provider console.

**Times are off by one hour**
The `timezone` value does not match your location, or it is not a valid IANA name. Use `Europe/London`, not `GMT`. Run `tidewatch doctor` to see the resolved timezone.

**`error: rate limit exceeded (429)`**
The provider rejected too many requests. Raise `cache_ttl` so tidewatch reuses tide tables longer, or raise the watch `--interval`. NOAA allows about five requests per minute per key.

**Blank table in watch mode**
The terminal does not support screen clearing, or output is piped. Watch mode needs an interactive terminal. Use `tidewatch once` in a loop instead:

```bash
while true; do tidewatch once; sleep 300; done
```

**Stale data after a station change**
The cache holds the old table. Delete the cache directory `~/.cache/tidewatch` or wait for `cache_ttl` to expire.

## License

MIT. See `LICENSE` for the full text.
