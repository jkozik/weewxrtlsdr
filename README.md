# weewxrtlsdr

<img width="1659" height="939" alt="image" src="https://github.com/user-attachments/assets/58aec354-f720-48a7-9659-c5018d8d3a63" />


I have a good old Davis Vantage Pro2 weather station.  It has been working great for years.  It serves [NapervilleWeather.com](https://NapervilleWeather.com). I want to retire:  the [Davis Envoy receiver](https://www.davisinstruments.com/products/wireless-weather-envoy?gad_source=1&gad_campaignid=270431645&gbraid=0AAAAADiof7Mmtgt6YCyhGQCfyq5q-Mmqx&gclid=CjwKCAjw0LzWBhBOEiwAKQd0cAsHRdru3xO5j2Ybs5SiEXy0WhCFt_qcLHTsZBrAyJnY1ZBMQHOCzRoCJtkQAvD_BwE) with the RTL-SDR.COM dongle and the [Cumulus Windows 10 software](https://www.cumuluswiki.org/a/About_Cumulus) with the Weewx weather application. 

Above is the target architecture.  I plug a [RTL-SDR.COM](https://www.amazon.com/s?k=rtl+-+sdr&hvadid=694262491571&hvdev=c&hvexpln=67&hvlocphy=9021701&hvnetw=g&hvocijid=4284003291645549062--&hvqmt=e&hvrand=4284003291645549062&hvtargid=kwd-302602789869&hydadcr=13584_13388478&mcid=1299fef0be0c37399eb7e79df975d1fc&tag=googhydr-20&ref=pd_sl_7kmj3vvegp_e_p67) dongle into my Dell R330 server, I run [Weewx](https://weewx.com/) in an Ubuntu VM, I get indoor temperature, humidity and pressure data from an [M5 Stack's](https://www.amazon.com/M5Stack-M5StickC-Development-mounting-Accessories/dp/B0D6LF4GJL) [ENV-III](https://www.amazon.com/M5Stack-Temperature-Humidity-Pressure-QMP6988/dp/B0FNNGJ7QJ/ref=sr_1_1?crid=Q5HQ68Y9XAYO&dib=eyJ2IjoiMSJ9.AVYhxiB8dqJIaopL01jR4VMU4JRUd4ByEVE-23LbUnRjf4bBvq5Dq6YjgY-s-ljkGB3b_jfoPP72RxCMzqYjmFgaoIpZHBLPqVwnJzIGWP8.EchkyoI9fC2LjRI0iV5YGnY2TB0J_h4GIo2_elgx6Xk&dib_tag=se&keywords=ENV-3+sensor&qid=1792002036&s=electronics&sprefix=env-3+sensor%2Celectronics%2C129&sr=1-1) sensor pack over a [mosquito](https://mosquitto.org/)-based [MQTT](https://mqtt.org/) server.  

The Weewx software collects the weather data, keeps it in a [SQLite](https://www.sqlite.org/) database.  Periodically it generates reports.  The reports are formated for an [NGINX](https://nginx.org/) server, at [weewxrtlsdr.kozik.net](https://weewxrtlsdr.kozik.net/)
and also by using the [weewx-saratoga](https://github.com/ktrue/weewx-saratoga) extension it ftp's realtime reports, graphs and historical records to a container that runs the website [NapervilleWeather.com](https://napervilleweather.com/index.php) by using [Ken True's Saratoga Weather website template](https://saratoga-weather.org/scripts.php)s. 

The table below summarizes the Ins/Outs:

| Link | What | Where configured |
|---|---|---|
| Radio | Davis ISS, channel 1, US band → `rtldavis` | `weewx.conf` `[Rtldavis]` |
| MQTT | `m5-env3/sensor/indoor_{temperature,humidity,pressure}/state` → inTemp, inHumidity, pressure | `weewx.conf` `[MQTTSubscribeService]`; broker = mosquitto container :1883 |
| FTP | clientraw.txt, NOAA reports, PNGs → `192.168.100.208:30421` | `weewx.conf` `[[FTP]]` |
| Web | local preview on :8080 | `docker-compose.yml` nginx |

This is just a piece of an end-to-end solution
- The M5Stick-ENV3 is setup and programmed separately.  With source code stored in a future repository.
- The NapervilleWeather.com website is programmed in a different repository.


The weewx container has three outputs from the one station:
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

This repository creates three containers
- Weewx.  The main weather software plus extentions
- Nginx.  The Weewx software generate weather graphes.  This nginx container serves them.
- Mosquito.  A generic MQTT server.  This brings T/H/P indoor weather data to the Weewx application.

There's also a backup script that very nicely backs up the installation and database and sends a tar file to an external NAS.

## Background on how weewx uses the RTL-SDR to decode the Vantage Pro2 RF signal

A Davis Vantage Pro2 has no "data port" on the outdoor unit. The ISS (Integrated
Sensor Suite) just broadcasts a short radio packet about every 2.5 seconds in the
915 MHz band, hopping between 51 frequencies in a fixed pattern so it doesn't sit
on one channel. Normally only Davis hardware (a console or an [Envoy](https://www.davisinstruments.com/products/wireless-weather-envoy?variant=39617694498977&country=US&currency=USD&utm_medium=product_sync&utm_source=google&utm_content=sag_organic&utm_campaign=sag_organic&gad_source=1&gad_campaignid=22288934145&gbraid=0AAAAADiof7MiQ1gZQZzfAPBlquInYB1Su&gclid=CjwKCAjw0LzWBhBOEiwAKQd0cPFJ-h__P3AafskidOSkV7Vg2JjJg5lwKgZxSaUVBomr7CV4GcCzWRoCBGwQAvD_BwE)) knows how to
follow that hopping and read the packets.

The creative part of this project is replacing that purpose-built receiver with a
~$30 RTL-SDR.COM dongle, a TV-tuner chip that software can retune to almost any
frequency, and doing the receiver's job in software. `rtldavis` tunes the dongle,
follows the ISS's hop sequence, demodulates the raw radio signal into bits, checks
each packet's CRC, and prints the good ones. The `weewx-rtldavis` driver runs
`rtldavis` inside the weewx container, reads that output, and turns the bytes into
weather values. Each packet carries wind speed and direction plus one other sensor
(temperature, humidity, rain, solar, UV, battery) in rotation. weewx stores them
like any other station. All of this rests on years of community work
reverse-engineering the Davis protocol; see [Credits](#credits).

```
   Davis ISS                RTL-SDR dongle             weewx-rtldavis container
 (outdoor sensors)          (USB stick)
 ┌──────────────┐  radio   ┌──────────────┐   USB    ┌──────────────────────────┐
 │ wind, temp,  │ ~~~~~~~> │ TV-tuner     │ ───────> │ librtlsdr                │
 │ humidity,    │ 915 MHz  │ chip, tuned  │   raw    │   talks to the dongle    │
 │ rain, solar, │ 51-chan  │ by software  │ samples  │            │             │
 │ UV, battery  │ hopping  │              │          │            ▼             │
 └──────────────┘  ~2.5 s  └──────────────┘          │ rtldavis                 │
                                                     │   follow the hops,       │
                                                     │   demodulate, check CRC  │
                                                     │            │             │
                                                     │            ▼             │
                                                     │ weewx-rtldavis driver    │
                                                     │   bytes → weather values │
                                                     │            │             │
                                                     │            ▼             │
                                                     │ weewx                    │
                                                     │   store, graph, report   │
                                                     └──────────────────────────┘
```

## Background on how indoor temp/hum/pres is collected using M5StickC

The RTL-SDR only hears the outdoor ISS. Indoor temperature, indoor humidity and
barometric pressure never went over the radio: the Davis Envoy measured them with
its own built-in sensors. Retiring the Envoy means losing those three readings,
including the station's only barometer, so something else has to measure them.

That something is a tiny ESP32 computer, an M5StickC PLUS2, with an M5Stack ENV III
sensor unit plugged into it (an SHT30 for temperature and humidity, a QMP6988 for
pressure). It runs a small firmware built with [ESPHome](https://esphome.io/): every
30 seconds it reads the sensors and publishes the values over WiFi to an MQTT broker.

MQTT works like a bulletin board. A publisher posts short messages under a named
**topic**, which looks like a file path. The **broker** (the `mosquitto` container
here) holds the latest message for each topic and forwards it to every
**subscriber** that asked for that topic. The sensor and weewx never talk to each
other directly, so either one can restart without breaking the other. To the
software, each message is just a topic name plus a plain-text value:

```
m5-env3/sensor/indoor_temperature/state   22.9      (°C)
m5-env3/sensor/indoor_humidity/state      64.4      (%)
m5-env3/sensor/indoor_pressure/state      992.3     (hPa)
```

On the weewx side, the `MQTTSubscribeService` extension subscribes to those three
topics, keeps the latest value of each, and adds them to every packet coming from
the radio as `inTemp`, `inHumidity` and `pressure`. From then on weewx treats them
like readings from a real Davis console. It also converts the raw station pressure
into the sea-level barometer reading shown on the website.

```
  M5StickC PLUS2 + ENV III        mosquitto container          weewx container
  (indoors, on WiFi)              (MQTT broker)
 ┌───────────────────────┐       ┌─────────────────┐       ┌─────────────────────────┐
 │ SHT30:   temp, hum    │       │                 │       │ MQTTSubscribeService    │
 │ QMP6988: pressure     │ ────> │  holds topics,  │ ────> │   keeps latest values,  │
 │                       │publish│  forwards each  │deliver│   adds them to every    │
 │ ESPHome firmware:     │       │  message to     │       │   LOOP packet           │
 │   every 30 s, read    │       │  subscribers    │       │            │            │
 │   sensors, publish    │       │                 │       │            ▼            │
 └───────────────────────┘       └─────────────────┘       │ weewx: inTemp,          │
                                                           │   inHumidity, pressure  │
                                                           └─────────────────────────┘
```

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
