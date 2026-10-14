# ---- builder: compile librtlsdr and rtldavis from source ----
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git pkg-config libusb-1.0-0-dev golang-go ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# librtlsdr — steve-m fork specifically; rtldavis documents a dependency on
# this fork, and mixing it with the apt rtl-sdr/librtlsdr-dev packages
# risks symbol/version conflicts.
RUN git clone --depth 1 https://github.com/steve-m/librtlsdr.git /src/librtlsdr \
    && cmake -S /src/librtlsdr -B /src/librtlsdr/build -DCMAKE_INSTALL_PREFIX=/opt/rtldavis \
    && cmake --build /src/librtlsdr/build -j"$(nproc)" \
    && cmake --install /src/librtlsdr/build

# rtldavis — lheijst fork; cgo links against the librtlsdr just installed above
ENV CGO_CFLAGS="-I/opt/rtldavis/include"
ENV CGO_LDFLAGS="-L/opt/rtldavis/lib -lrtlsdr"
ENV GOBIN=/opt/rtldavis/bin
RUN go install github.com/lheijst/rtldavis@latest

# ---- final: felddy/weewx image + the compiled artifacts above ----
FROM felddy/weewx:5.1
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/*
# weewx-saratoga's rtcr.py still imports the Python 2/3 compat shim `six`,
# not present in this image's venv. felddy/weewx points PIP_TARGET/PYTHONPATH
# at /data/lib/python/site-packages for its own runtime pip-install mechanism,
# but /data is bind-mounted at runtime and would shadow anything installed
# there at build time — override both so this lands in the venv itself.
RUN env -u PIP_TARGET -u PYTHONPATH /opt/venv/bin/pip install --no-cache-dir six
# MQTTSubscribe (weewx-mqtt/subscribe) needs the paho-mqtt client; same
# PIP_TARGET/PYTHONPATH shadowing issue as six above.
RUN env -u PIP_TARGET -u PYTHONPATH /opt/venv/bin/pip install --no-cache-dir paho-mqtt
USER weewx
COPY --from=builder /opt/rtldavis/bin/rtldavis /opt/rtldavis/bin/rtldavis
COPY --from=builder /opt/rtldavis/lib/librtlsdr.so* /opt/rtldavis/lib/
