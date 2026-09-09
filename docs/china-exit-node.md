# Raspberry Pi China Exit Node

A self-hosted setup for reaching mainland-China-geolocked streaming (CCTV-5+ and
friends) from outside China, using a Raspberry Pi on a Chinese residential
connection as the exit.

Everything here is self-hosted. No commercial VPN or "back to China" service is
involved.

---

## 1. Why this design

CNTV's stream API gates on the client's country. The check is visible in its
response:

```json
"lc": { "country_code": "US" },
"play": "0",
"tip_msg": "您所在的地区，暂不支持播放该视频"
```

`country_code` must be **`CN`**. Two consequences drive the whole design:

**A Hong Kong server does not work.** HK is its own ISO country code and CNTV
treats it as overseas, exactly like a US address. If you already run a
Shadowsocks box in HK, it cannot pass this check — but it is still useful here
as a rendezvous point (§3).

**You cannot fake it in software.** Forged `X-Forwarded-For`, `X-Real-IP`,
`Client-IP`, `CF-Connecting-IP`, `True-Client-IP`, and `X-Originating-IP` are
all ignored; the response stays `country_code: US`. TCP needs a return path, so
a real mainland IP is required. That is the one irreducible piece.

Residential is strongly preferred over a mainland VPS: CNTV blacklists known
Alibaba/Tencent cloud ranges precisely because they are used this way.

### Architecture

Chinese home broadband is nearly always behind CGNAT, so nothing can dial *into*
the Pi. The Pi dials *out* to a rendezvous box with a public IP, and everything
rides that tunnel — both your admin SSH and the proxy data path.

```
  Mac (US)                 HK box (public IP)              Pi (China, CGNAT)
     |                            |                              |
     |  sing-box  ── SS2022 ────► :8388 ──┐                      |
     |  ssh -p 2222 ──────────────► :2222 ──┤  frps               |
     |                            |         └──◄── frpc tunnel ──┤
     |                            |                              |
     └────────────── video (direct from CDN) ◄─────────  CNTV ◄──┘
```

The HK box forwards two ports down the tunnel to the Pi. It never terminates
the proxy itself — it is a relay only.

### Bandwidth: the two-tier question

There are two classes of request, and they may not be gated the same way:

| Tier | Endpoint | Volume | Gated? |
|------|----------|--------|--------|
| 1 | `vdn.live.cntv.cn/api2/live.do` | ~2 KB per stream start | **Confirmed yes** |
| 2 | `.m3u8` + `.ts` from `kcdnvip.com` / `myalicdn.com` | ~1–3 GB/hour | **Unverified** |

If Tier 2 turns out to be ungated, only the tiny API call crosses the Pi and
video streams direct from the CDN at full speed — the Pi needs almost no
bandwidth, and the caretaker's home connection never notices. §9 tells you how
to find out and how to narrow the routing if so.

---

## 2. What you need

- A Raspberry Pi (any model with ethernet; a 3B+ or newer is plenty) plus SD card
  and PSU. Cheap and widely available on Taobao — often easier to have your
  contact in China buy the hardware locally and mail only the SD card.
- **Ethernet, not WiFi.** This is what makes the setup possible for a
  non-technical caretaker: the instructions become "plug this into the router,
  plug in power." No WiFi password to relay, nothing to type.
- A rendezvous host with a public IP. Your existing HK Shadowsocks box works.
- Someone in China willing to host it. It is their connection and their IP
  making the requests — have that conversation before you mail hardware.

Secrets used below; generate your own and keep them out of version control:

```bash
openssl rand -hex 32     # frp token (shared by frps + frpc)
openssl rand -base64 32  # Shadowsocks SERVER_PSK
openssl rand -base64 32  # Shadowsocks CLIENT_PSK
```

---

## 3. HK rendezvous box

Install frp and open port 7000 plus the two forwarded ports.

`/etc/frp/frps.toml`:

```toml
bindPort = 7000

auth.method = "token"
auth.token  = "YOUR_FRP_TOKEN"

# only hand out the two ports we actually use
allowPorts = [
  { start = 2222, end = 2222 },   # -> Pi's sshd
  { start = 8388, end = 8388 },   # -> Pi's shadowsocks
]
```

Install and run:

```bash
FRP_VER=$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest \
          | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)
curl -fsSL "https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_amd64.tar.gz" \
  | sudo tar xz -C /usr/local/bin --strip-components=1 frp_${FRP_VER}_linux_amd64/frps
sudo systemctl enable --now frps
```

Make sure your firewall/security group allows inbound 7000, 2222, and 8388.

---

## 4. Prepare the SD card

Do all of this **before** the card goes to China.

### 4.1 Flash with Raspberry Pi Imager

Choose Raspberry Pi OS Lite (64-bit). Open the customization panel (gear icon)
and set:

- **Hostname** — e.g. `cn-exit`
- **Enable SSH → public-key only**, pasting your `~/.ssh/id_ed25519.pub`.
  Do not enable password auth.
- **Locale/timezone** — `Asia/Shanghai`
- Leave WiFi blank; you are using ethernet.

Imager writes a `firstrun.sh` to the boot partition and wires it into
`cmdline.txt` for you.

### 4.2 Add the provisioning files

The boot partition mounts as `bootfs`. On Raspberry Pi OS Bookworm and later it
lives at `/boot/firmware` once running; on older releases it is `/boot`. Copy
onto it:

- `frpc.toml` (below)
- `frpc.service` (below)
- `provision-pi.sh` (below)

`frpc.toml` — note `loginFailExit = false`, which keeps the Pi retrying forever
if HK is unreachable at boot instead of giving up:

```toml
serverAddr = "YOUR_HK_HOST"
serverPort = 7000

auth.method = "token"
auth.token  = "YOUR_FRP_TOKEN"

loginFailExit = false

[[proxies]]
name        = "ssh"
type        = "tcp"
localIP     = "127.0.0.1"
localPort   = 22
remotePort  = 2222

[[proxies]]
name        = "ss"
type        = "tcp"
localIP     = "127.0.0.1"
localPort   = 8388
remotePort  = 8388
```

`frpc.service`:

```ini
[Unit]
Description=frp client (phone home)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frpc -c /etc/frp/frpc.toml
Restart=always
RestartSec=10
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
```

`provision-pi.sh` — installs frp, enables the hardware watchdog, and hardens the
filesystem against power loss:

```bash
#!/usr/bin/env bash
set -euo pipefail

FRP_VER="$(curl -fsSL https://api.github.com/repos/fatedier/frp/releases/latest \
           | sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' | head -1)"
case "$(uname -m)" in
  aarch64) ARCH=arm64 ;;
  armv7l|armv6l) ARCH=arm ;;
  x86_64) ARCH=amd64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

echo ">> installing frp ${FRP_VER} (${ARCH})"
tmp=$(mktemp -d)
curl -fsSL "https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_${ARCH}.tar.gz" \
  | tar xz -C "$tmp" --strip-components=1
install -m755 "$tmp/frpc" /usr/local/bin/frpc
install -d -m700 /etc/frp
install -m600 /boot/firmware/frpc.toml /etc/frp/frpc.toml 2>/dev/null \
  || install -m600 /boot/frpc.toml /etc/frp/frpc.toml
install -m644 /boot/firmware/frpc.service /etc/systemd/system/frpc.service 2>/dev/null \
  || install -m644 /boot/frpc.service /etc/systemd/system/frpc.service
rm -rf "$tmp"

echo ">> hardware watchdog (reboot if the kernel hangs)"
modprobe bcm2835_wdt || true
grep -q bcm2835_wdt /etc/modules || echo bcm2835_wdt >> /etc/modules
grep -q '^dtparam=watchdog=on' /boot/firmware/config.txt 2>/dev/null \
  || echo 'dtparam=watchdog=on' >> /boot/firmware/config.txt 2>/dev/null \
  || echo 'dtparam=watchdog=on' >> /boot/config.txt
apt-get update -qq && apt-get install -y -qq watchdog
sed -i 's/^#\?watchdog-device.*/watchdog-device = \/dev\/watchdog/' /etc/watchdog.conf
sed -i 's/^#\?max-load-1.*/max-load-1 = 24/' /etc/watchdog.conf
systemctl enable --now watchdog

echo ">> SD-card resilience (power cuts are inevitable)"
sed -i 's|\(\s/\s\+ext4\s\+\)defaults|\1defaults,noatime,commit=120|' /etc/fstab || true

echo ">> enabling phone-home"
systemctl daemon-reload
systemctl enable --now frpc
systemctl enable ssh

echo ">> done."
systemctl --no-pager -l status frpc | head -20
```

### 4.3 Wire it into first boot

Append to the `firstrun.sh` that Imager generated, just before its final
`exit 0`:

```bash
bash /boot/firmware/provision-pi.sh 2>&1 | tee /var/log/provision-pi.log
```

Do not hand-edit `cmdline.txt` — Imager already pointed `systemd.run` at
`firstrun.sh`, and adding a second entry will break the boot.

### 4.4 Test it on your own desk first

**Boot the finished card on a Pi at home, on your own ethernet, and confirm it
phones home before you ship it.** Debugging a provisioning bug through a
relative in another timezone who does not read English error messages is
miserable, and a bad card means the hardware is simply dead on arrival.

---

## 5. First boot in China

Instructions for the caretaker, in full:

> Plug the network cable into any spare port on the router. Plug in the power.
> That's it — leave it alone.

From your Mac, within a minute or two:

```bash
ssh -p 2222 pi@YOUR_HK_HOST
```

If that fails, check `frps` logs on the HK box for a connection attempt — that
tells you whether the Pi reached the rendezvous at all, which splits the problem
cleanly in half.

---

## 6. Shadowsocks server on the Pi

The old Python `shadowsocks` with `aes-256-cfb` is not suitable here. That
cipher is an unauthenticated stream cipher, and a mainland-hosted server taking
connections from overseas sits squarely in the path of active probing — no
integrity check is exactly the property probing exploits. Use Shadowsocks-2022,
which is AEAD with replay protection and stays silent on malformed input.

This repository's own image serves this role directly — it builds
shadowsocks-rust for `linux/arm64` and `linux/arm/v7`, so it runs on the Pi as-is:

```bash
docker buildx build --platform linux/arm64 -t ss .
docker run -d --restart always --network host \
  ss -s 127.0.0.1:8388 -k "$SERVER_PSK" -m 2022-blake3-aes-256-gcm
```

The rest of this section uses sing-box instead, which is a reasonable
alternative if you would rather not run Docker on the Pi.

On the Pi:

```bash
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://sing-box.app/gpg.key | sudo tee /etc/apt/keyrings/sagernet.asc >/dev/null
sudo chmod a+r /etc/apt/keyrings/sagernet.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/sagernet.asc] https://deb.sagernet.org/ * *" \
  | sudo tee /etc/apt/sources.list.d/sagernet.list
sudo apt update && sudo apt install -y sing-box
```

`/etc/sing-box/config.json`:

```json
{
  "log": { "level": "info" },
  "inbounds": [
    { "type": "shadowsocks",
      "listen": "127.0.0.1",
      "listen_port": 8388,
      "method": "2022-blake3-aes-256-gcm",
      "password": "SERVER_PSK",
      "users": [ { "name": "mac", "password": "CLIENT_PSK" } ] }
  ],
  "outbounds": [ { "type": "direct" } ]
}
```

Binding to `127.0.0.1` is deliberate — frpc reaches it locally, and it is never
exposed on the Chinese LAN.

```bash
sudo systemctl enable --now sing-box
```

---

## 7. Self-hosted DNS (unbound on the Pi)

CNTV's CDN uses GeoDNS. If your resolver looks American you get overseas edges
no matter how good the tunnel is. Running a recursive resolver *on the Pi* fixes
this and removes any third-party resolver from the path: queries to CNTV's
authoritative servers originate from a mainland IP, so the GeoDNS answers are
correct by construction.

```bash
sudo apt install -y unbound
```

`/etc/unbound/unbound.conf.d/exit-node.conf`:

```
server:
    interface: 127.0.0.1
    port: 5353
    access-control: 127.0.0.0/8 allow
    do-ip6: no
    hide-identity: yes
    hide-version: yes
    cache-min-ttl: 60
    prefetch: yes
```

```bash
sudo systemctl enable --now unbound
dig @127.0.0.1 -p 5353 +short vdn.live.cntv.cn   # sanity check
```

The Mac reaches this through the Shadowsocks tunnel — see `dns-cn` below.

---

## 8. Mac client

```bash
brew install sing-box
```

`~/.config/sing-box/client.json`:

```json
{
  "log": { "level": "info" },

  "dns": {
    "servers": [
      { "tag": "dns-cn",    "address": "udp://127.0.0.1:5353", "detour": "ss-cn" },
      { "tag": "dns-local", "address": "local" }
    ],
    "rules": [
      { "domain_suffix": [ "cntv.cn", "cctv.com", "cctvpic.com",
                           "myalicdn.com", "kcdnvip.com" ],
        "server": "dns-cn" }
    ],
    "final": "dns-local",
    "strategy": "ipv4_only"
  },

  "inbounds": [
    { "type": "mixed", "tag": "in", "listen": "127.0.0.1", "listen_port": 1080 }
  ],

  "outbounds": [
    { "type": "shadowsocks",
      "tag": "ss-cn",
      "server": "YOUR_HK_HOST",
      "server_port": 8388,
      "method": "2022-blake3-aes-256-gcm",
      "password": "SERVER_PSK:CLIENT_PSK" },
    { "type": "direct", "tag": "direct" }
  ],

  "route": {
    "rules": [
      { "domain_suffix": [ "cntv.cn", "cctv.com", "cctvpic.com",
                           "myalicdn.com", "kcdnvip.com" ],
        "outbound": "ss-cn" }
    ],
    "final": "direct"
  }
}
```

Three details that are easy to get wrong:

- **`"detour": "ss-cn"` on `dns-cn` is load-bearing.** It sends the DNS query
  through the tunnel so it resolves from the Pi's unbound. Without it you
  resolve from your home ISP, get overseas CDN edges, and the stream fails even
  though the tunnel is perfectly healthy. This is the single most common way
  these setups break.
- **`"server": "YOUR_HK_HOST"`** — not the Pi. HK forwards 8388 down the tunnel.
- **`"strategy": "ipv4_only"`** is not cosmetic. If your ISP gives you working
  IPv6 and any CCTV domain publishes AAAA records, macOS will prefer IPv6 and
  route straight around the tunnel.

Point your browser's SOCKS proxy at `127.0.0.1:1080`, or run sing-box in TUN
mode to capture everything.

---

## 9. Verification

Test with `curl`, never the browser. When geo-blocked, the API returns **decoy**
URLs — `cctv5plus_2.png`, `cctv5plus_2.json`, and the literal string
`yangshi?group&drm=1&cctv5&zbzx` — so a video player just fails silently and
tells you nothing.

```bash
curl -s --proxy socks5h://127.0.0.1:1080 \
  -H 'Referer: https://tv.cctv.com/' \
  'https://vdn.live.cntv.cn/api2/live.do?channel=pa://cctv_p2p_hdcctv5plus&client=html5' \
  | python3 -m json.tool
```

Use `socks5h` — the `h` forces DNS through the tunnel too.

Success looks like `"country_code": "CN"`, `"play": "1"`, and real `.m3u8` URLs
in `hls_url` instead of the decoys.

### Settling the Tier 2 question

Take the real `.m3u8` URL from that response and fetch it — plus one `.ts`
segment — **with the proxy off**:

```bash
curl -sI 'THE_REAL_M3U8_URL' | head -1
```

- **200** → the CDN does not gate independently. Narrow the routing so only
  `vdn.live.cntv.cn` goes through China and drop the CDN domains from both the
  `route` and `dns` rules. Video then streams direct at full speed and the Pi
  carries a couple of kilobytes per channel switch.
- **403 / 4xx** → the CDN gates too. Keep the full domain list, and expect
  ~1–3 GB/hour across the Pi.

---

## 10. Operating a box you cannot reach

**The only intervention you can ever ask for is a power cycle.** Nobody is
attaching a monitor and keyboard. Every rule below follows from that.

- Never leave the box in a state a power cycle cannot recover. When you change
  frp or sing-box config, verify the service comes up *and* survives
  `systemctl reboot` before you rely on it.
- Change one thing at a time. A config error that kills `frpc` costs you a phone
  call in a bad timezone.
- The hardware watchdog reboots on kernel hang; `Restart=always` with
  `StartLimitIntervalSec=0` restarts frpc forever; `loginFailExit = false`
  survives HK being down at boot. Do not remove these.
- SD cards die. Keep a known-good image so a replacement card can be mailed
  without redoing this from scratch.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ssh -p 2222` refused | frpc not running, or HK firewall blocks 2222. Check frps logs for a connection attempt. |
| frps shows no connection | Pi has no network, or `serverAddr`/token wrong. |
| Tunnel up, `country_code` still `US` | Traffic is not actually traversing the Pi. Test with `--proxy socks5h://` explicitly. |
| `country_code` `CN` but stream stalls | DNS resolving outside the tunnel — check `detour` on `dns-cn`. |
| Works on curl, fails in browser | Browser not using the proxy, or IPv6 leak. Confirm `strategy: ipv4_only`. |
| Worked, then stopped | Pi's IP rotated into a blocked range, or ISP rebooted the CGNAT mapping. Restart frpc. |

---

## 11. Notes

Accessing this content from outside China is contrary to CCTV's terms of
service. It is also why mainland cloud providers prohibit proxy hosting on their
instances, which is a practical reason to prefer a residential connection.

CCTV-5's geo-block exists mostly for territorial sports rights, so major events
are frequently licensed to a broadcaster wherever you are — often the simpler
path for a one-off match.
