# weewxrtlsdr
<img width="1674" height="941" alt="image" src="https://github.com/user-attachments/assets/3085b144-8813-4046-9fc2-7005e59d3289" />


| Link | What | Where configured |
|---|---|---|
| Radio | Davis ISS, channel 1, US band → `rtldavis` | `weewx.conf` `[Rtldavis]` |
| MQTT | `m5-env3/sensor/indoor_{temperature,humidity,pressure}/state` → inTemp, inHumidity, pressure | `weewx.conf` `[MQTTSubscribeService]`; broker = mosquitto container :1883 |
| FTP | clientraw.txt, NOAA reports, PNGs → `192.168.100.208:30421` | `weewx.conf` `[[FTP]]` |
| Web | local preview on :8080 | `docker-compose.yml` nginx |


A second, independent weewx instance that decodes a Davis ISS transmitter
directly over RF, using an RTL-SDR dongle and the `rtldavis` driver — side by
side with an existing Envoy-fed weewx instance on the same host, to
cross-check Envoy data against a direct RF decode.

It serves three outputs from the one station:
- A normal weewx `Seasons`-skin website (this repo's own nginx container).
- A Cumulus-compatible realtime/graph/NOAA feed (`weewx-saratoga` extension),
  delivered by FTP to an external website that renders it with the Saratoga
  Weather Templates.
- `gauge-data.txt` (a dedicated `SteelSeriesGauge` skin) for that same
  external site's SteelSeries gauges page — a separate file/format from
  `clientraw.txt`, using the gauge package's own upstream weewx template
  rather than a third-party extension.

Indoor temperature/humidity/pressure — which the RF decode can never provide,
since those come from the console's own onboard sensors, not the ISS
transmission — come from a separate M5StickC PLUS2 + M5Stack ENV III Unit
(SHT30 + QMP6988) running ESPHome, publishing over MQTT to a `mosquitto`
container bundled in this repo's `docker-compose.yml`. weewx's
`MQTTSubscribeService` (`weewx-mqtt/subscribe` extension) subscribes and
merges the three values into every LOOP packet.

## Recreating this from scratch

### 1. Host prerequisites (outside Docker — not covered by this repo)

These have to be redone by hand on any new host; nothing here is portable
automatically.

- **RTL-SDR dongle visible to the host.** If it's passed through from a
  hypervisor (USB passthrough to a VM, etc.), that's configured outside this
  repo entirely. Verify: `lsusb | grep 0bda:2838` (or your dongle's ID).
- **Blacklist the DVB kernel modules** that otherwise claim the dongle before
  `librtlsdr` can:
  ```
  sudo tee /etc/modprobe.d/blacklist-rtlsdr-dvb.conf <<'EOF'
  blacklist dvb_usb_rtl28xxu
  blacklist rtl2832_sdr
  EOF
  sudo update-initramfs -u
  sudo reboot
  ```
  Verify after reboot: `lsmod | grep -iE 'dvb|rtl2832'` prints nothing.
- **udev rule + group access**, so the container can open the device
  unprivileged. `steve-m/librtlsdr`'s udev rule sets the device node to
  `root:plugdev`, mode `660`:
  ```
  sudo cp <a librtlsdr build's> /etc/udev/rules.d/rtl-sdr.rules /etc/udev/rules.d/
  sudo udevadm control --reload-rules && sudo udevadm trigger
  getent group plugdev   # note the gid
  ```
  `docker-compose.yml`'s `group_add: ["46"]` hardcodes **this host's**
  `plugdev` gid — check `getent group plugdev` on the new host and update
  that number, it is not portable as-is.
- Both of the above need a real TTY for the `sudo` password — they can't run
  from an unattended script.

### 2. Configure secrets and bring up the stack

```
git clone <this repo> && cd weewxrtlsdr
cp data/weewx.conf.example data/weewx.conf
# edit data/weewx.conf: [[FTP]] password = ... (see "Secrets" below)
docker compose up -d --build
```

`librtlsdr` and `rtldavis` are compiled from source in the `Dockerfile`'s
multi-stage build — no separate host-side build step. The `weewx-saratoga`
extension's files and its `weewx.conf` additions are already baked into
`data/bin/user/` and `data/weewx.conf.example` (tracked in git), so there's
no `weectl extension install` step to re-run on a fresh clone — copying the
example config and building is enough.

### 3. Verify

- `docker compose logs weewx` — LOOP packets should show real decoded values
  (`outTemp`, `windDir`, etc.) within a few minutes; the RF sync-up takes a
  little while.
- `curl -I localhost:8080` — the local `Seasons` site.
- `docker compose logs weewx | grep ftpgenerator` — the FTP push to the
  external site succeeding, at the archive interval (5 min by default).
- `docker compose logs weewx | grep mqttsubscribe` — confirms the MQTT
  connection/subscriptions; `inTemp`/`inHumidity`/`pressure` should show real
  values in LOOP packets once the indoor sensor is flashed and publishing
  (see "Indoor sensor hardware" below — it's separate hardware, not
  something `docker compose up` alone provides).

## Secrets

`data/weewx.conf` is git-ignored (it's the live config, holds a real FTP
password) — `data/weewx.conf.example` is the tracked template with
`password = replace_me`. This is the same "example file, gitignored real
file" pattern as `.env`/`.env.example`, just applied to weewx's single
monolithic config file since weewx has no native env-var substitution. When
weewx.conf changes in a way worth keeping (a new report stanza, a driver
tweak), copy the change into `weewx.conf.example` too, with any credential
redacted back to `replace_me`.

## Indoor sensor hardware (outside this repo)

Not reproduced by `docker compose` at all — a physical **M5StickC PLUS2**
(ESP32 host) + **M5Stack ENV III Unit** (SHT30 + QMP6988, connected via its
Grove cable) needs to be flashed with ESPHome and joined to the same LAN as
this host. `data/weewx.conf.example`'s `[MQTTSubscribeService]` stanza
expects it to publish plain numeric values (not JSON) to:
```
m5-env3/sensor/indoor_temperature/state   (°C)
m5-env3/sensor/indoor_humidity/state      (%)
m5-env3/sensor/indoor_pressure/state      (hPa)
```
to the bundled `mosquitto` container on port `1883`, anonymous auth. If a
replacement device ever uses different topic names, update the
`[[[<topic>]]]` section names under `[MQTTSubscribeService][[topics]]`
to match — the mapping is entirely by topic string, not device identity.

## Known gotchas

- **A new skin's `skin.conf` needs an explicit `[Generators]
  generator_list = ...` line**, or weewx silently does nothing for that
  report — no error at the default `INFO` log level, just a `DEBUG`-only
  `No generators specified for report '<name>'`. Every skin here already
  has this; it's the one thing to double check when adding a new one from
  scratch instead of copying an existing skin.conf as a starting point.
- **`MQTTSubscribeService` corrupts shared packet fields unless configured
  carefully** — the single most important gotcha in this repo, since it
  fails silently (no errors, no crashes; LOOP packets look completely
  correct) and only shows up as archive records permanently stuck at
  `None`. Its `target_data` dict always includes `usUnits` and `dateTime`
  keys, and `event.packet.update(target_data)` blindly overwrites the
  *whole packet's* copies of both — not just the fields it's actually
  merging — on every single call, whether or not there was new data for
  that topic. Both are already handled correctly in this repo's
  `data/weewx.conf.example` (`unit_system = US` + per-field `units =`
  overrides; `ignore_end_time = true`), but if you ever add a new MQTT
  topic/field and don't extend the *same* `[[topics]]` block, you can very
  easily reintroduce this. See `NOTES.md`'s 2026-09-25 entries for the full
  diagnosis.
- **`data/public_html` ownership**: if `data/` is ever wiped and recreated,
  a `docker compose up` mount-order race can let the Docker daemon create
  that directory as `root` before the `weewx` container claims it as its own
  user, breaking every report-image write with `Permission denied`. Fix:
  `docker run --rm -v "$PWD/data/public_html:/target" alpine chown 1000:1000 /target`.
- **Static skin assets need a fresh process start**: weewx only copies a
  skin's `copy_once` files (`seasons.css`, `favicon.ico`, etc.) on the very
  first report cycle after `weewxd` starts — that flag is in-memory, not
  retried. If the site ever looks unstyled, `docker compose restart weewx`
  before assuming something's actually broken (especially after fixing the
  permission issue above, which likely broke that first cycle).
- **`six`/`paho-mqtt` modules**: `weewx-saratoga`'s `rtcr.py` and
  `weewx-mqtt/subscribe`'s `mqttsubscribe.py` need `six` and `paho-mqtt`
  respectively, neither present in the base image. Already handled in the
  `Dockerfile` — the tricky part is that `felddy/weewx` points
  `PIP_TARGET`/`PYTHONPATH` at the bind-mounted `/data`, which shadows
  anything installed there at build time, so each `pip install` has to
  override both env vars to land in the venv instead. Any *other* Python
  extension added later that needs a pip dependency will hit this same
  issue — same fix applies.
- **MQTT data silently dropped**: `MQTTSubscribeService` connects and
  subscribes fine even when data never reaches a LOOP packet — watch
  `docker compose logs weewx` for `TopicManager ignoring record outside of
  interval`. `adjust_start_time`/`adjust_end_time` default to `0`, and if the
  MQTT publisher's interval is longer than the gap between `rtldavis`'s LOOP
  packets (~2-3s), messages land just outside that narrow window and get
  dropped. Already set to `60` under `[MQTTSubscribeService][[topics]]`
  (the ENV III publishes every 30s) — widen further if a slower-publishing
  sensor is ever added.
- **Mosquitto log file**: don't add a `log_dest file ...` line to
  `mosquitto/config/mosquitto.conf` without also fixing ownership —
  mosquitto drops privileges to a dedicated `mosquitto` user (uid `1883`)
  that can't write into a bind-mounted directory pre-created by a normal
  user. `log_dest stdout` (the current config) avoids the issue entirely;
  `docker logs mosquitto-weewxrtlsdr` is enough for this use case.

## Credits

- [weewx](https://weewx.com/) (Tom Keffer et al.) — the core weather
  station software.
- [felddy/weewx](https://github.com/felddy/docker-weewx) — the Docker image
  this is built on.
- [steve-m/librtlsdr](https://github.com/steve-m/librtlsdr) — the RTL-SDR
  driver library.
- [lheijst/rtldavis](https://github.com/lheijst/rtldavis) (Luc Heijst,
  building on dekay's original) and
  [jpoirier/gortlsdr](https://github.com/jpoirier/gortlsdr) — decode the
  Davis ISS protocol over RF.
- [weewx-rtldavis](https://github.com/lheijst/weewx-rtldavis) — the weewx
  driver wrapping `rtldavis`.
- [weewx-saratoga](https://github.com/ktrue/weewx-saratoga) (Ken True,
  saratoga-weather.org), based on Gary Roderick's (gjr80) original
  `weewx-wd`/`weewx-realtime_clientraw`/`weewx-stackedwindrose` extensions —
  generates the Cumulus-compatible realtime/tag/graph feed.
- [Saratoga Weather Templates](https://saratoga-weather.org/wxtemplates/) —
  the PHP/AJAX website templates this feed is meant for.
- [weewx-mqtt/subscribe](https://github.com/weewx-mqtt/subscribe) (Rich Bell
  — relocated here from the now-archived `bellrichm/WeeWX-MQTTSubscribe`) —
  the `MQTTSubscribeService` that merges the indoor sensor's MQTT data into
  weewx.
- [ESPHome](https://esphome.io/) and [Eclipse Mosquitto](https://mosquitto.org/)
  — firmware and broker for the M5StickC PLUS2 + ENV III indoor sensor.
