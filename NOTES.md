# Development notes / history

A chronological log of what was built and why, and the real bugs hit along
the way. `README.md` is the "how to recreate this" reference — this file is
the "how did we get here, and what did we learn" record.

## 2026-09-16 — Phase 1: get the RF decode working

Goal: stand up a second weewx instance decoding the same Davis ISS
transmitter directly over RF (`rtldavis`), independent of the existing
Envoy-fed instance, to cross-check the two.

- Blacklisted the guest's DVB kernel modules (`dvb_usb_rtl28xxu`,
  `rtl2832_sdr`) so `librtlsdr` could claim the dongle; required a reboot.
- Built `librtlsdr` (steve-m fork) and `rtldavis` (lheijst fork) on the host
  filesystem first, bind-mounted into the container — deliberately manual at
  this stage, to debug hardware/USB/permissions issues without also fighting
  a Docker build.
- **Bug**: the container's `weewx` user couldn't open the USB device node
  (`root:plugdev`, mode `660`) — fixed with `group_add: ["46"]` (this host's
  `plugdev` gid) in `docker-compose.yml`.
- **Bug**: `felddy/weewx`'s entrypoint runs a *hardcoded*
  `weectl station create --no-prompt` on first launch when no config exists
  yet, silently ignoring any CLI flags passed to `docker compose run`. Station
  location/lat/lon ended up wrong on the first attempt; fixed by editing
  `weewx.conf` directly instead of relying on `station create` flags.
- **Bug**: `docker compose up` has a mount-order race — `nginx`'s
  `./data/public_html:ro` bind mount got created by the Docker daemon as
  `root` before `weewx` could claim it, breaking every report-image write.
  Fixed with a throwaway `alpine` container doing the `chown` (no host sudo
  needed).
- **Bug** (knock-on from the above): weewx only copies a skin's
  `copy_once` static assets (`seasons.css`, `favicon.ico`) on the very first
  report cycle after `weewxd` starts — an in-memory flag, not retried. That
  first cycle had failed on the permission bug above, so the site stayed
  unstyled until the container was restarted (giving it a fresh "first run").
- Verified live ISS decode end-to-end: real `outTemp`/`windDir`/battery-status
  values in LOOP packets, not simulator placeholders.

## 2026-09-16 — Phase 2: reproducible build

- Rewrote `Dockerfile` as multi-stage: a `builder` stage compiles `librtlsdr`
  + `rtldavis` from source, the final stage copies in just the compiled
  artifacts. Removed the host-built `vendor/` bind mount entirely —
  `docker compose up -d --build` now reproduces the software stack with no
  manual build step.
- `git init` + `.gitignore` mirroring the sibling `weewx51` repo's pattern
  (generated `archive/`, `public_html/`, `bin/` contents excluded), with one
  deliberate exception: `data/bin/user/rtldavis.py` tracked despite
  `data/bin/` being otherwise ignored, since without it a fresh clone can't
  load the driver.

## 2026-09-16 — Disk space (unrelated maintenance)

A Zabbix alert (`/` at 82% used) turned out to be ~17-20 months of
accumulated unused Docker images and build cache, unrelated to this project.
Cleaned up ~5GB via `docker image prune -a` / `docker builder prune -a` /
`docker container prune`. Left `/backup`'s weekly snapshot rotation
untouched — that's an intentional, separate retention policy.
(Correction 2026-10-13: there was no retention at the time; tarballs
accumulated forever. See the 2026-10-13 entry below.)

## 2026-09-17 — Saratoga template feed

Goal: generate a Cumulus-compatible realtime/graph/NOAA feed so this
station's data can drive the Saratoga Weather Templates on an external
website, potentially replacing a Windows/Cumulus VM entirely.

Before touching anything, inspected the *actual* target — SSH'd into the
Kubernetes control node (`192.168.100.208`) and read the real, running
`nwcom` (napervilleweather.com) deployment's `Settings.php`/
`Settings-weather.php` and its `ajaxWEEWXwx.js`/`wxgraphs.php`/
`check-fetch-times.php` source, rather than guessing the data contract from
extension docs alone. Found the Saratoga template package has a first-class,
built-in `WXsoftware = 'WEEWX'` mode — distinct from (and much simpler than)
the Cumulus-native file layout the existing `nwcom` deployment uses — and
confirmed weewx's own stock NOAA-report and image-generator filenames
already match what WEEWX mode expects almost exactly.

- Installed `weewx-saratoga` (`ktrue/weewx-saratoga` — the gjr80 original was
  removed from GitHub 2025-06-01; Ken True, who helped develop it, maintains
  the continuation).
- **Bug**: the extension's installer wrote a doubled `HTML_ROOT` value
  (`public_html/public_html/saratoga`) into `weewx.conf`. Flattened to plain
  `public_html` — matches the "flat delivery is fine" decision below anyway.
- **Bug**: `weewx-saratoga`'s `rtcr.py` imports the Python 2/3 compat shim
  `six`, not present in the `felddy/weewx` image. Fixed in the `Dockerfile`
  with `pip install six` — but `felddy/weewx` points `PIP_TARGET`/
  `PYTHONPATH` at the bind-mounted `/data`, which shadows anything installed
  there at build time, so that `pip install` has to override both env vars
  to land in the venv instead of a path that gets shadowed at runtime.
- Renamed `tempfeel` → `tempchill` in the `Seasons` skin's day/week/month/year
  image stanzas (4 places, plus the `plot_groups` list) to match the exact
  filename (`*tempchill.png`) the Saratoga templates look for.
- Configured `[[FTP]]` to push to a separately-provisioned FTP server
  (`192.168.100.208:30421`) targeting an NFS-backed directory the future
  `weewxrtlsdr` Kubernetes deployment will mount read-only — decided to
  deliver everything flat rather than replicate the existing Cumulus-style
  `cumulus/`/`saratoga/` subdirectory split, since WEEWX mode doesn't use it.
- Deferred to a separate future session: building the actual
  `weewxrtlsdr` Kubernetes deployment (new Docker image variant with
  `WEEWX-plugin.zip` instead of `CU-plugin.zip`, new PV/PVC, Service,
  HTTPRoute) and wiring up `post_clientraw.php` for true sub-archive-interval
  (15s) realtime push — `min_interval = 15` is configured and the local
  `clientraw.txt` already refreshes that fast, but nothing is pulling it
  that quickly yet.

## 2026-09-17 — Repo hygiene before first commit

- Found a real secret about to be committed: the FTP password was sitting in
  plaintext in the tracked `data/weewx.conf`. Split into a gitignored real
  file and a tracked `data/weewx.conf.example` (password redacted to
  `replace_me`, matching the convention weewx already uses for its other
  credential fields in the same file) — the `.env`/`.env.example` pattern,
  applied to weewx's one monolithic config file.
- Found 8 of `weewx-saratoga`'s 9 Python files weren't being tracked at all —
  the `.gitignore`'s exception only covered `rtldavis.py`. Widened it to
  cover everything in `data/bin/user/` except the two stock files
  `weectl station create` regenerates on its own (`__init__.py`,
  `extensions.py`).

## 2026-09-25 — Indoor sensor: M5StickC PLUS2 + ENV III over MQTT

Goal: cover the sensors RF decode can never provide (`inTemp`, `inHumidity`,
`pressure` — these come from the console/Envoy's own onboard sensors, not
the ISS RF transmission), using an M5StickC PLUS2 + ENV III Unit
(SHT30 + QMP6988) running ESPHome, publishing over MQTT.

- Added a bundled `mosquitto` service to `docker-compose.yml` (no existing
  broker on the network) — anonymous auth, since this never leaves the LAN.
  **Bug**: mosquitto couldn't write its log file — the `./mosquitto/log`
  bind-mount directory was pre-created by `mkdir` as `jkozik` (uid 1000),
  but the container drops privileges to a dedicated `mosquitto` user
  (uid 1883) that can't write there. Simplest fix: dropped file-based
  logging entirely (`log_dest stdout` only, viewable via `docker logs`),
  removing the need for that bind mount altogether.
- Verified the ESP32's `weewx-mqtt/subscribe` (bellrichm's original
  `WeeWX-MQTTSubscribe` project relocated to this org — the old repo is
  archived) is live and current before installing it — same "verify before
  trusting a repo name" lesson as the earlier gjr80/`weewx-saratoga` case.
- Used the extension's own `mqttsubscribe.py configure service
  --print-configspec` / `--validate` tooling to get the authoritative config
  syntax, rather than trusting web docs (which turned out to be incomplete/
  outdated on the exact "individual payload" field-mapping syntax anyway).
- **Bug**: `paho-mqtt` (the extension's MQTT client dependency) hit the exact
  same `PIP_TARGET`/`PYTHONPATH` shadowing issue as `six` did for
  weewx-saratoga — same fix in the `Dockerfile` (override both env vars for
  that one `pip install`).
- **Bug** (the subtle one): after wiring up `MQTTSubscribeService`, it
  connected and subscribed fine, but no data ever reached a LOOP packet —
  logs showed `TopicManager ignoring record outside of interval`.
  `adjust_start_time`/`adjust_end_time` default to `0`, and the ESP32
  publishes every 30s while `rtldavis` emits LOOP packets every ~2-3s, so
  MQTT data almost always landed just outside the narrow window between two
  consecutive LOOP packet timestamps and got silently dropped. Fixed by
  setting both to `60` under `[[topics]]`.
- Confirmed end-to-end: real `inTemp`/`inHumidity`/`pressure` values in LOOP
  packets, with `StdPressureCooker` immediately auto-deriving `altimeter`
  from the injected `pressure` (as originally planned when this integration
  was first spec'd out) with zero extra config.

## 2026-09-25 — Indoor sensor: two more real bugs before it actually persisted

LOOP packets showed correct `inTemp`/`inHumidity`/`pressure` values (see
above), but the *archive database* kept writing `None` for all three, every
5-minute interval, indefinitely. Two separate bugs, found by instrumenting
`weewx/engine.py` and `weewx.accum` directly (isolated repros using the
real config + real captured packets kept succeeding, which is what forced
digging into the actual running process instead of trusting theory):

- **Bug 1 — `usUnits` corruption**: `MQTTSubscribeService` merges data into
  the LOOP packet via `event.packet.update(target_data)`, and `target_data`
  *always* includes a `usUnits` key matching the `[[topics]] unit_system`
  setting — even on packets where the topic had no new data to merge. With
  `unit_system = METRIC` configured, this silently flipped every packet's
  overall declared unit system from `1` (US, matching `rtldavis` and the
  rest of the packet) to `17` (METRICWX), corrupting how every *other*
  field in the packet got interpreted downstream. Fixed by setting
  `unit_system = US` (matching the packet's real, existing unit system) and
  adding per-field `units = degree_C` / `units = hPa` overrides so the
  *incoming* MQTT values still get interpreted correctly. (`units = percent`
  for humidity turned out to be rejected by the extension's own validation —
  omitted, since relative humidity is unitless-identical across systems
  anyway.)
- **Bug 2 — `dateTime` corruption (the real culprit for the archive loss)**:
  even after fixing `usUnits`, records still weren't persisting. Traced it
  to `TopicManager.get_accumulated_data()`: it also always sets
  `target_data['dateTime']` to its own internally-accumulated MQTT message
  timestamp — which can be up to `adjust_end_time` seconds stale — and a
  guard the code *does* provide for this (`if ignore_end_time:
  target_data['dateTime'] = end_time # Force dateTime to packet's datetime
  so packet datetime is not updated to the MQTT datetime`) only applies
  when `ignore_end_time = true`, which defaults to `false` and wasn't set.
  So every merge could jump the *entire packet's* `dateTime` backward or
  forward by up to ~60 seconds. `StdArchive`'s accumulator uses that
  timestamp to decide interval membership, so these jumps triggered
  spurious `OutOfSpan` resets — discarding the whole accumulator (every
  field in it, not just the MQTT ones) before the real 5-minute boundary
  ever arrived. Fixed with `ignore_end_time = true` under `[[topics]]`.
- Confirmed via direct SQLite queries that archive records now persist real
  `inTemp`/`inHumidity`/`pressure`/`barometer`/`altimeter` values, and that
  `weewxrtlsdr.kozik.net`'s Current Conditions widget renders them.

## 2026-09-28 — SteelSeries gauges: gauge-data.txt

Goal: the Saratoga template test site (a separate deployment, at
`192.168.100.128:8086`, being built by another Claude Code session) needed
`gauge-data.txt` for its SteelSeries gauges page — a genuinely different
file/format from `clientraw.txt`, not something `weewx-saratoga` already
produces.

- The other session's first suggestion was `gjr80's weewx-realtime_gauge-data`
  extension — checked first, same pattern as before: gone (404), and the
  forks found were either 9 years stale (2017) or archived (August 2025).
  Declined to install any of them.
- Found a much simpler path instead: `mcrossley/SteelSeries-Weather-Gauges`
  (the actual gauge display package — already part of the `.128` host's
  image, since `InstallNW.com`'s Dockerfile downloads it) ships its own
  `weather_server/WeeWX/gauge-data.txt.tmpl` — a plain, standard weewx
  Cheetah template, not a third-party service. No extension install, no new
  Python dependency, no new bug surface — just the same `CheetahGenerator`
  mechanism already used for `NOAA-%Y-%m.txt.tmpl` etc.
- Added a new dedicated `SteelSeriesGauge` skin
  (`data/skins/SteelSeriesGauge/`) with that one template, and a new
  `[[GaugeDataReport]]` stanza in `weewx.conf`, matching the
  `WEEWXtagsReport`/`ClientrawReport` pattern.
- **Bug** (simple, self-inflicted): forgot the `[Generators]
  generator_list = weewx.cheetahgenerator.CheetahGenerator` line in the new
  skin's `skin.conf`. Without it weewx silently skips the whole report —
  no error, no crash, just `DEBUG: No generators specified for report
  'GaugeDataReport'` (only visible with `debug=1`/`level=DEBUG`, not at the
  normal INFO level). Every other skin.conf in this repo has this line;
  this is the one thing to double check when adding a new skin from
  scratch rather than copying an existing one.
- Verified the actual generated output satisfies the three checks
  `gauges.js` requires in WeeWX mode (per the `.128` session): `ver` is
  `"14"`, `timeUTC` is `"YYYY,MM,DD,HH,MM,SS"` in UTC, and `dateFormat`
  (`y.m.d h:m`) matches the `date` field's actual format — all correct
  automatically, since this is the real upstream template rather than a
  hand-built one.
- **Known limitation, accepted for now**: this updates on the normal
  5-minute archive cycle, not truly live like `clientraw.txt`
  (`RealtimeClientraw` is a hand-written loop-bound service;
  `gauge-data.txt.tmpl` is a plain archive-triggered template and has no
  equivalent). Upgrading to sub-minute updates later would mean writing a
  small custom service modeled on `rtcr.py`.

## 2026-10-13 — Log limits and weekly backup

- Docker logs: no container had a log size cap (no /etc/docker/daemon.json).
  The weewx51 `weewx` container's log hit 18G and filled /. Added
  `logging: json-file, max-size 10m, max-file 3` to all three services in
  docker-compose.yml (backup of the old file: docker-compose.yml.pre-loglimits).
- Backup: added `weewxrtlsdrbck.sh` (this directory), separate from
  ~/weewx51/weewxbck.sh, which only covers ~/weewx51. It runs from root's
  crontab on Sundays at 23:30 and logs to weewxrtlsdrbck.log. It rsyncs the
  project to /backup/weewxrtlsdrBck/project and snapshots weewx.sdb and
  weewxwd.sdb with SQLite's online backup API (no container stop). It then
  tars to /backup/weewxrtlsdr.YYYYMMDD.HH.tar.gz and FTPs the tarball to
  192.168.100.143:/weewx (login in ~/.ncftp-backup.cfg, chmod 600).
  Retention is 84 days, pruned only after a successful new tarball. The
  weewx51 script got the same 84-day retention.
- Restore: untar, copy db/*.sdb into data/archive/ with the containers
  stopped, then copy the project/ tree back.

## 2026-10-25 — One missing archive record, traced to a transient MQTT reconnect

A Saratoga Template page flagged humidity as `--` on 2026-10-24 around
11:35-11:40am Central. Investigation:

- Confirmed the archive table has no row at all for the 11:35:00 interval
  that day (`SELECT dateTime FROM archive WHERE dateTime BETWEEN ...`
  simply skips from 11:30:00 to 11:40:00 — a clean 10-minute gap where
  every other interval is 5 minutes). Not a null-valued row; the row never
  got written.
- This lines up exactly with an MQTT disconnect/reconnect on the
  `m5-env3` topic logged at 11:36:24/11:37:24 that day (mosquitto/
  mqttsubscribe reconnected cleanly on its own, but something in that
  window kept the whole archive interval from being committed, not just
  the MQTT-sourced fields).
- No recurrence found anywhere else in the month's data; every other
  archive interval checked, before and after, is intact.
- Fix applied on the Saratoga Template (website) side: it now handles a
  `--`/missing reading gracefully instead of surfacing it as an error.
  Nothing changed on the weewxrtlsdr side for this — treated as a one-off
  transient blip, not a recurring bug to chase further right now.
