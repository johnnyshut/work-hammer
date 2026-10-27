FROM debian:bookworm-slim AS build

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential git pkg-config ca-certificates python3 gettext \
      autoconf automake libtool \
      libssl-dev libxml2-dev zlib1g-dev liblz4-dev vpnc-scripts \
 && git clone --depth 1 https://gitlab.com/openconnect/openconnect.git /src/openconnect \
 && cd /src/openconnect \
 && ./autogen.sh \
 && ./configure --prefix=/usr/local --with-openssl --without-gnutls --disable-nls \
      --without-stoken --without-libpcsclite \
      --with-vpnc-script=/usr/share/vpnc-scripts/vpnc-script \
 && make -j"$(nproc)" \
 && make install

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates iproute2 openssl libssl3 libxml2 zlib1g liblz4-1 \
      vpnc-scripts microsocks \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/sbin/openconnect /usr/local/sbin/openconnect
COPY --from=build /usr/local/lib/libopenconnect.so* /usr/local/lib/
RUN ldconfig /usr/local/lib
