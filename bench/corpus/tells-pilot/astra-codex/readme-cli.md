`tidewatch` polls tide tables for a list of harbours and prints the next high tide and low tide. Use it for a quick terminal check, a live display, or structured input to another program.

Each result includes the harbour, tide type, predicted time, and height. By default, times use the harbour’s local time zone, and heights use metres. Heights follow the source table’s reference level, which can differ between harbours.

## Installation

`tidewatch` requires Python 3.11 or later. Install it with `pipx` to keep its dependencies separate from other Python applications:

```sh
pipx install tidewatch
```

Confirm that the command is available:

```sh
tidewatch --version
```

If your shell cannot find the command, run `pipx ensurepath`, then open a new terminal.

To upgrade an existing installation:

```sh
pipx upgrade tidewatch
```

The first request requires an internet connection. After a successful request, `tidewatch` keeps a local copy of the tide table for temporary connection failures. You do not need an account for the default tide-table service.

## Usage

Run `tidewatch` with one or more harbour identifiers. The command fetches their tables, prints the next events, and exits. It selects each next event independently, so a low tide can appear before a high tide.

### 1. Check one harbour

```sh
tidewatch --harbour plymouth-uk
```

Example output:

```text
HARBOUR       EVENT  LOCAL TIME              HEIGHT
plymouth-uk   LOW    2026-09-22 10:42 +01:00   1.2 m
plymouth-uk   HIGH   2026-09-22 16:58 +01:00   4.8 m
```

Each harbour has its own pair of results. Dates and UTC offsets make events clear when predictions cross midnight or a daylight-saving transition. These sample values illustrate the output format.

### 2. Monitor several harbours

```sh
tidewatch --harbour plymouth-uk --harbour brest-fr --watch --interval 5m
```

Repeat `--harbour` for each location. Watch mode polls immediately, then repeats at the specified interval. It refreshes the terminal display after each poll. Press `Ctrl+C` to stop.

Intervals accept seconds, minutes, or hours, such as `30s`, `5m`, or `1h`. The minimum interval is 30 seconds. Without `--interval`, watch mode polls every 15 minutes.

### 3. Produce JSON for a script

```sh
tidewatch --harbour cork-ie --format json --timezone UTC > tides.json
```

JSON output contains a `harbours` array. Each harbour includes its identifier, source, retrieval time, cache status, and next high and low tide. Event times use ISO 8601 timestamps with explicit offsets. Heights are numeric values with a separate unit field.

Diagnostics go to standard error, so redirected standard output contains only JSON.

## Configuration

Save persistent settings in `~/.config/tidewatch/config.toml`:

```toml
harbours = ["plymouth-uk", "brest-fr"]
interval = "15m"
timezone = "harbour"
units = "metres"
format = "table"
timeout = 10
cache_max_age = "6h"
```

With this file, running `tidewatch` checks both configured harbours. Add `--watch` when you want continuous polling. Configuration alone does not enable watch mode.

Set `timezone` to `harbour`, `UTC`, or an IANA time-zone name such as `Europe/Paris`. Set `units` to `metres` or `feet`. The `timeout` value sets the maximum duration of each request in seconds.

Command-line options override matching configuration values. If you supply any `--harbour` options, they replace the configured harbour list for that run.

Use `--config PATH` to select another file. Relative paths resolve from the current directory. An invalid configuration stops execution and reports the affected setting.

## Troubleshooting

**The command reports an unknown harbour.**  
Use `tidewatch harbours` to list supported identifiers. Harbour names can be ambiguous, so requests require the full identifier, including its region suffix.

**A request times out.**  
Check your connection and retry. For a slow connection, increase `timeout`. Each harbour request runs independently, so one failed request does not prevent other results.

**The output shows cached data.**  
The service could not supply a fresh table. `tidewatch` labels cached results and shows their retrieval time. It selects upcoming events from that table. If the cache exceeds `cache_max_age`, the harbour becomes unavailable.

**Times appear incorrect.**  
Check the displayed UTC offset and your configured time zone. Also check your computer’s clock. Event selection depends on the current time.

**A script reports failure.**  
Exit code `0` means every requested harbour has results. Code `1` means at least one harbour is unavailable. Code `2` indicates invalid arguments or configuration. Cached results count as available within the configured age limit.
