# plex-oci-proxy

Give friends and family remote access to your Plex server **without an inbound port
forward** and **without publishing your home IP address**, using a small free-tier cloud VM
as the public front door and Tailscale as the private link back home.

```
viewer ──HTTPS──▶ cloud VM (Caddy, TLS, geo filter) ──Tailscale──▶ your Plex server :32400
```

This is a runbook, not a product. It describes a setup that has been running in production
for a household's remote viewers (Roku, smart TVs, phones, browsers, car browsers), along
with every trap hit while building it. Follow it top to bottom, or hand
[AGENT_PROMPT.md](AGENT_PROMPT.md) to a coding agent and let it walk you through it.

---

## Contents

1. [Why do this](#1-why-do-this)
2. [Architecture](#2-architecture)
3. [Alternatives considered](#3-alternatives-considered)
4. [What you need](#4-what-you-need)
5. [Build guide](#5-build-guide)
   - [Phase 1: Cloud account](#phase-1-cloud-account)
   - [Phase 2: The VM and its two firewalls](#phase-2-the-vm-and-its-two-firewalls)
   - [Phase 3: Tailscale on the VM](#phase-3-tailscale-on-the-vm)
   - [Phase 4: Tailscale on your Plex host](#phase-4-tailscale-on-your-plex-host)
   - [Phase 5: DNS and Caddy](#phase-5-dns-and-caddy)
   - [Phase 6: Geo filtering (optional)](#phase-6-geo-filtering-optional)
   - [Phase 7: Plex settings](#phase-7-plex-settings)
   - [Phase 8: Close the old port forward](#phase-8-close-the-old-port-forward)
   - [Phase 9: Tailnet ACL](#phase-9-tailnet-acl)
   - [Phase 10: Harden the VM](#phase-10-harden-the-vm)
   - [Phase 11: Monitoring](#phase-11-monitoring)
6. [Tailscale on common Plex hosts](#6-tailscale-on-common-plex-hosts)
7. [Verification checklist](#7-verification-checklist)
8. [Troubleshooting and gotchas](#8-troubleshooting-and-gotchas)
9. [Maintenance](#9-maintenance)
10. [Rollback](#10-rollback)
11. [Files in this repo](#11-files-in-this-repo)

---

## 1. Why do this

Plex's built-in Remote Access works by forwarding a port on your router to the server. That
has three costs:

- **An open inbound port** on your home network, pointing at an app that has had CVEs.
- **Your home IP address is published** to anyone who can reach the server, and through
  Plex's discovery to every client you share with.
- **No control point.** There is nothing in front of Plex where you can filter, log, or
  rate-limit.

This design fixes all three:

| Goal | How |
|---|---|
| No inbound port forward | The home side only makes an *outbound* Tailscale connection |
| Home IP never published | DNS points at the cloud VM; the home IP appears nowhere public |
| A control point in front of Plex | Caddy on the VM: TLS, logs, headers, optional geo filtering |

**What it costs:** one extra moving part (the VM), one extra network hop, and a monthly
egress allowance (10 TB on Oracle's free tier, which is a lot of Plex).

---

## 2. Architecture

### Before

```
viewer ──▶ plex.tv discovery ──▶ HOME-WAN-IP:32400 (router port forward) ──▶ Plex server
```

### After

```
                          ┌──────────────────── Cloud VM (public IP) ─────────────────────┐
viewer ──HTTPS :443──────▶│ host firewall (iptables + optional ipset geo allowlist)       │
  (plex.example.com,      │   └─▶ Caddy :443 ── TLS terminates here (Let's Encrypt)        │
   plain DNS A record)    │         └─▶ reverse_proxy <plex-tailnet-ip>:32400             │
                          └───────────────────────────────┬───────────────────────────────┘
                                                          │ Tailscale (WireGuard), direct
                                                          │ peer path via UDP 41641
                          ┌───────────────────────────────▼───────────────────────────────┐
                          │ Home network (NAT, no inbound ports)                           │
                          │   Plex server :32400  (bare metal, VM, NAS, or container)      │
                          └────────────────────────────────────────────────────────────────┘

LAN clients: unchanged. They still connect directly to the server on the LAN.
```

### Traffic and ports on the VM

| Port | Who reaches it | Purpose | Filter |
|---|---|---|---|
| TCP 443 | Viewers | Plex over HTTPS | Geo allowlist (optional) |
| TCP 80 | Let's Encrypt, browsers | ACME HTTP-01 challenge + redirect to HTTPS | **Must stay open to the world** (see F2) |
| UDP 41641 | Tailscale peers | Direct WireGuard path to home | Open to the world (WireGuard is authenticated) |
| TCP 22 | You | SSH | **Tailnet only** once built; not exposed publicly |

### Why each piece is there

- **Cloud VM.** The only thing with a public IP. It is disposable: if it is ever
  compromised, you delete it, and your home address was never on it.
- **Caddy.** Gets and renews its own Let's Encrypt certificate with a three-line config.
  Plex streams are long-lived, so do **not** add write or idle timeouts.
- **Tailscale.** The home server dials out. Your router needs no forward. The VM has a
  public IP, so it is the end that accepts the direct peer connection; this is why UDP 41641
  must be open on the VM.
- **Tailnet ACL.** Without one, the internet-facing VM can reach *every* port on *every*
  device in your tailnet. The ACL caps it at the Plex port and nothing else.
- **Plain DNS record.** If you use Cloudflare, the record must be **DNS only (grey cloud)**.
  See [section 3](#3-alternatives-considered).

### What the viewer experiences

Nothing changes for them. Plex advertises your custom URL (`https://plex.example.com:443`)
to their apps through plex.tv, and the apps connect there. They do not install anything.

---

## 3. Alternatives considered

| Option | Verdict | Why |
|---|---|---|
| **Router port forward** (Plex default) | Rejected | Open port, home IP published |
| **Port forward + a DNS A record to home** | Rejected | Worse: a guessable `plex.yourdomain` hostname makes your home IP *easier* to find than Plex's own `*.plex.direct` wildcard certificates do |
| **Cloudflare proxy (orange cloud) or Cloudflare Tunnel** | Rejected | Cloudflare's terms restrict serving video through the CDN without a paid product, and enforcement is account-wide: it can take your *other* proxied sites down with Plex. Cloudflare also terminates and can inspect the TLS. If you must, use a separate account and a separate domain |
| **Plex Relay** | Rejected | Capped at about 1–2 Mbps and forces transcoding |
| **Tailscale on every viewer's device** | Rejected for viewers | Roku, most smart TVs and consoles can't run a Tailscale client |
| **Cloud VM + Caddy + Tailscale** (this repo) | **Chosen** | Meets all three goals; free-tier capable; the VM is disposable |

---

## 4. What you need

- **A Plex Media Server** you administer, on any host in [section 6](#6-tailscale-on-common-plex-hosts).
- **A domain name** where you can create an A record.
- **A Tailscale account** (the free Personal plan is enough).
- **A cloud VM** with a public IPv4 address. This guide uses **Oracle Cloud Infrastructure
  (OCI) Always Free** (Ampere A1 arm64), but any small Linux VPS works: Caddy and Tailscale
  use almost no CPU, so pick on **bandwidth allowance** and **distance to your viewers**.
  Check that a provider's cheap tier is actually sold in a region near you: some budget
  VPS lines are available only in certain regions, and a VM on another continent adds a
  transatlantic round trip to every stream.
- **About 3–4 hours** for a first build, including waiting on the cloud account.
- An SSH key pair on your workstation.

### Choosing the VM region

Pick a region **close to your home and your viewers**. Every stream crosses home → VM → viewer,
so a region on another continent adds that round trip twice. Measured cost of a nearby region:
about 30–40 ms home→VM, and no measurable throughput loss for viewers.

### Oracle Cloud notes

- **Upgrade to Pay As You Go (PAYG).** Pure Always Free accounts are subject to *idle
  reclamation*: Oracle can reclaim an instance whose 95th-percentile CPU, network and memory
  stay under 20% for 7 days, and a quiet proxy can easily qualify. PAYG accounts are exempt,
  and Oracle states that Always Free resources stay free after the upgrade. Set a $1 budget
  alert so any surprise charge is visible.
- **The free-tier limits change.** In 2026 Oracle cut the Always Free A1 allowance in half
  without much notice. A proxy needs 1 OCPU / 6 GB or less, so the current limits are still
  plenty, but check them on Oracle's Always Free page before you build.
- **Egress: 10 TB/month free.** Only VM→viewer traffic counts. A 60 Mbps 4K direct play is
  about 27 GB/hour, so 10 TB is roughly 370 hours of worst-case 4K per month.
- **"Out of host capacity"** on A1 shapes is common in busy regions. Retry later, or try
  another availability domain.
- **Your home region is permanent.** Choose it carefully at sign-up.

---

## 5. Build guide

**Placeholders used throughout.** Replace these with your own values:

| Placeholder | Meaning |
|---|---|
| `plex.example.com` | The public hostname viewers will use |
| `203.0.113.10` | The VM's public IPv4 address (reserved) |
| `100.64.0.10` | The **Plex server's** Tailscale IP |
| `100.64.0.20` | The **VM's** Tailscale IP |
| `<LAN-CIDR>` | Your home LAN, e.g. `10.0.10.0/24` |

> **Order matters.** Build the new path *alongside* your existing port forward, prove it
> works end to end, and only then turn the old forward off (Phase 8). At every point before
> Phase 8, rolling back is just "stop using the new URL".

### Phase 1: Cloud account

1. Create the Oracle Cloud account and choose your home region.
2. Enable MFA. Oracle doesn't hand you recovery codes, so also enable the **Bypass Code**
   factor (Identity & Security → Domains → Default → Security → MFA) and store a code in
   your password manager.
3. Upgrade to **Pay As You Go**: Billing & Cost Management → *Upgrade and Manage Payment*.
   - Provisioning and the upgrade can each take a while. "Your account provisioning is in
     progress" only clears with time; signing out and in doesn't help.
   - **Ignore the "Free Tier account / Free Trial" banner after upgrading.** It's stale and
     can persist for weeks. The *Upgrade and Manage Payment* page is what to trust.
4. Create a **budget**: root compartment, $1, alert at 100% of actual spend.

### Phase 2: The VM and its two firewalls

5. Create the instance:
   - Shape `VM.Standard.A1.Flex`, **1 OCPU / 6 GB** is plenty.
   - Image: **Ubuntu 24.04** (the login user is `ubuntu`; `opc` is for Oracle Linux).
   - Upload your SSH public key.
   - IPv6: leaving it off is simpler (one firewall ruleset, one geo list). See
     [F9](#f9-one-mobile-carrier-is-very-slow-to-the-vm) for the trade-off.
   - The in-wizard cost estimate (about $2/month for the boot volume) ignores the free
     200 GB block-storage allowance. Check real spend in Cost Analysis after 48 hours.
6. **Switch to a reserved public IP now, before anything depends on it.** The default IP is
   ephemeral: stable across reboots, but lost if the instance is ever rebuilt. OCI can't
   convert it in place: unassign the ephemeral IP, then assign a **reserved** one (free; up
   to 2 per tenancy), which will be a *different* address. A reserved IP belongs to your
   tenancy, so a rebuilt VM can reuse it and your DNS never changes.
   > A dynamic-DNS client on the VM is *not* a substitute. The only thing that changes an
   > OCI ephemeral IP is destroying the instance, and the DDNS client dies with it.
7. **Cloud firewall (OCI Security List → ingress rules)**, source `0.0.0.0/0`:
   - TCP 80, TCP 443, **UDP 41641**
   - TCP 22 **from your own public IP `/32` only**, temporarily, for setup. You'll remove
     it in Phase 10.
8. **Host firewall.** Oracle's Ubuntu image ships with iptables whose INPUT chain **ends in a
   `REJECT` rule**. Rules appended after it never match. Find its position first:

   ```bash
   sudo iptables -L INPUT -n --line-numbers     # note the line number N of the REJECT rule
   sudo iptables -I INPUT N -p tcp --dport 80    -j ACCEPT
   sudo iptables -I INPUT N -p tcp --dport 443   -j ACCEPT   # replaced in Phase 6 if geo filtering
   sudo iptables -I INPUT N -p udp --dport 41641 -j ACCEPT
   sudo netfilter-persistent save
   ```

   Each `-I INPUT N` inserts above the REJECT and pushes it down, so N stays correct for
   all three lines.
9. Set the timezone so logs read naturally: `sudo timedatectl set-timezone <Region/City>`.
10. Set a password for `ubuntu` (`sudo passwd ubuntu`) and store it. Ubuntu cloud images
    have no console password, so the OCI **serial console**, your break-glass if SSH ever
    fails, is useless until you do this. SSH stays key-only, so this doesn't weaken SSH.

### Phase 3: Tailscale on the VM

11. Install and join, with an explicit hostname (otherwise it registers with an odd name
    derived from the VNIC):

    ```bash
    curl -fsSL https://tailscale.com/install.sh | sudo sh
    sudo tailscale up --ssh=false --hostname=plex-proxy
    tailscale ip -4          # this is 100.64.0.20 in this guide
    ```

12. In the Tailscale admin console, **disable key expiry** for this node, and for the Plex
    host in Phase 4. **Both ends of the tunnel expire.** The one you didn't just build is
    the one you forget. (Tagged nodes, from Phase 9, have expiry disabled automatically.)

### Phase 4: Tailscale on your Plex host

13. Follow the recipe for your host type in **[section 6](#6-tailscale-on-common-plex-hosts)**.
    Note the Plex host's tailnet IP (`100.64.0.10` here).
14. **Confirm the tunnel is *direct*, not relayed.** From the VM:

    ```bash
    tailscale ping -c 8 100.64.0.10
    ```

    The first pongs may say `via DERP(xxx)` while the path negotiates. The last ones must
    say `via <ip>:<port>`. If it stays on DERP, UDP 41641 is blocked on one of the VM's two
    firewalls. Everything still *works* over DERP (HTTP 200s, playback), which is exactly
    why it goes unnoticed. Relays are shared, slower, and not meant for bulk video.
15. Confirm the VM can reach Plex: `curl -s http://100.64.0.10:32400/identity` should return
    XML containing `machineIdentifier`.

### Phase 5: DNS and Caddy

16. Create a DNS **A record**: `plex.example.com → 203.0.113.10`.
    - **Cloudflare: set Proxy status to "DNS only" (grey cloud).** Verify with
      `dig +short plex.example.com @1.1.1.1`. You should get *your VM's IP*, not a
      Cloudflare `104.x` / `172.6x.x` address.
    - **Don't** let a router's dynamic-DNS updater manage this record. Some (pfSense, for
      one) re-send the "proxied" flag on every update and will flip it back to orange.
      Manage it by hand; it's a static IP.
17. Install Caddy from its **official repository** (Ubuntu's own `caddy` package is years
    old). Follow <https://caddyserver.com/docs/install#debian-ubuntu-raspbian>.
18. Back up the stock config and install [examples/Caddyfile](examples/Caddyfile), edited
    for your hostname and the Plex host's tailnet IP:

    ```bash
    sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.orig
    sudo nano /etc/caddy/Caddyfile
    sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
    ```

    Caddy requests a Let's Encrypt certificate over HTTP-01 on port 80 on first start,
    usually within seconds. Watch `journalctl -u caddy -f`.
19. **Gate: test from outside the VM** (your workstation, not the VM itself; see
    [F6](#f6-you-cant-test-the-public-url-from-the-vm-itself)):

    ```bash
    curl -sS -o /dev/null -w '%{http_code} tls_verify=%{ssl_verify_result}\n' https://plex.example.com/identity
    # expect: 200 tls_verify=0
    ```

    Nothing at home has changed yet. Your old remote access still works in parallel.

### Phase 6: Geo filtering (optional)

If your old port forward only allowed certain countries, rebuild that here, or moving to the
VM silently drops the control. Skip this phase if you don't need it.

20. Install `ipset` and persistence:

    ```bash
    sudo apt-get install -y ipset ipset-persistent
    ```

21. Install [scripts/geo-allow-refresh.sh](scripts/geo-allow-refresh.sh) to
    `/usr/local/sbin/`, set `COUNTRIES` (lowercase ISO codes, e.g. `"us ca"`), and run it
    once. It builds the `geo_allow` set from ipdeny.com country zone files.

    ```bash
    sudo install -m 755 geo-allow-refresh.sh /usr/local/sbin/
    sudo /usr/local/sbin/geo-allow-refresh.sh
    sudo ipset test geo_allow <your-current-public-ip>     # must say "is in set"
    ```

22. **Check your own IP is in the set first**, then swap the open 443 rule for a filtered one:

    ```bash
    sudo iptables -L INPUT -n --line-numbers
    sudo iptables -I INPUT N -p tcp --dport 443 -m set --match-set geo_allow src -j ACCEPT
    sudo iptables -D INPUT -p tcp --dport 443 -j ACCEPT
    sudo netfilter-persistent save
    ```

23. Refresh daily: `/etc/cron.d/geo-allow-refresh`:

    ```
    17 4 * * * root /usr/local/sbin/geo-allow-refresh.sh >/dev/null 2>&1
    ```

24. **Reboot the VM now, while nothing depends on it**, and confirm the set, the rules, Caddy,
    and Tailscale all come back. `netfilter-persistent` loads ipsets (`10-ipset`) before
    iptables (`15-ip4tables`). If that ever broke, a rule referencing a missing set would fail
    to load and take the whole ruleset with it.

Rules that are easy to get wrong:

- **Never geo-filter port 80.** See [F2](#f2-never-geo-filter-port-80).
- **`maxelem`.** `ipset` defaults to 65,536 entries. The US alone is about 70,000 CIDRs. The
  script sets 300,000; without that, loading silently truncates and real users get blocked.
- **The script is last-good-wins**: it downloads and checks every zone before touching the
  live set, then swaps atomically. A failed download changes nothing.
- **Travelling?** Your own devices can run Tailscale. That lets you keep the allowlist to
  your home country rather than adding every country you visit.

### Phase 7: Plex settings

⚠️ This is the first phase that changes what existing users experience.

25. **Back up `Preferences.xml`** (only that file, not the multi-GB config directory). Also
    screenshot Settings → Remote Access.
26. In the **Plex web UI** (not by editing `Preferences.xml`; Plex rewrites it on shutdown),
    under Settings → **Network** (show advanced):

    | Setting | Value | Why |
    |---|---|---|
    | Custom server access URLs | `https://plex.example.com:443` | What plex.tv advertises to remote clients. **HTTPS only.** Never add an `http://` URL: port 80 is deliberately unfiltered, so it would give clients a path around the geo filter, and Caddy redirects it to HTTPS anyway |
    | Secure connections | `Preferred` | `Required` also affects local connections; HTTPS-only remote access already comes from the advertised URL |
    | LAN Networks | `<LAN-CIDR>` | Keeps home clients playing directly on the LAN instead of going out to the VM and back, which also saves egress |
    | List of IP addresses and networks that are allowed without auth | **Leave as is. Never add the VM's tailnet IP or `100.64.0.0/10`** | See the warning below |

27. Settings → **Remote Access → Disable.** You're replacing it. The setting takes effect
    without a restart.
28. **Test from a device that's genuinely off your network.** Phone on cellular is easiest.
    "Plays fine on Wi-Fi" proves nothing: on Wi-Fi the app connects straight to the LAN
    address and never touches the VM. Prove the stream went through the proxy by checking
    Caddy's access log for `/library/parts/` or `transcode/universal/session` requests, or
    Tautulli/Plex dashboard showing the client's address as the **VM's tailnet IP**.

> ⚠️ **The most dangerous setting in this whole build.** Once traffic goes through the proxy,
> **every remote viewer appears to Plex as the VM's tailnet IP** (`100.64.0.20`). Plex's
> *"allowed without auth"* list (`allowedNetworks`) **bypasses login entirely**. Put the VM's
> IP, or the `100.64.0.0/10` range, in that list and **anyone on the internet who can reach
> your URL gets your whole library with no password.** This is easy to do by accident while
> "fixing" a client that won't connect. Don't.
>
> The similarly named **LAN Networks** setting only affects bandwidth/quality decisions and is
> the safe one to use.

**Side effect to know about:** because all remote clients share the VM's address, per-user
IP geolocation in Tautulli and Plex no longer shows where viewers really are.

**Client quality caps.** If a remote stream looks soft or keeps transcoding, check the
*client app's* quality setting before blaming the server. The Roku app and the iOS app's
cellular setting both default to low bitrates. Set them to **Original/Maximum** and the
stream usually switches to Direct Play, which is better for the viewer and far lighter on
the server.

### Phase 8: Close the old port forward

29. **Disable** (don't delete) the router's Plex port forward. Keep it for a week or two as
    your rollback, then delete it. Record its exact settings first.
30. **Verify from a true outside vantage point.** Testing your own WAN IP from inside the LAN
    needs NAT reflection and proves nothing. The VM is a convenient outside machine:

    ```bash
    # from the VM: the old port should now be closed/filtered
    nc -vz -w 5 <your-home-wan-ip> 32400
    ```

    And from your workstation, `https://plex.example.com/identity` should still return 200.

At this point the goals are met: no inbound forward, and your home IP is published nowhere.

### Phase 9: Tailnet ACL

**Do this right after the build. It's the most important hardening step.** Tailscale's
default policy lets every device reach every other device. Your VM is the one machine that is
deliberately on the internet; if it's ever compromised, the default lets an attacker reach
SSH, NAS admin pages, SMB shares, and everything else on your tailnet.

Real example from building this: a desktop joined the tailnet during the hardening work and
was **immediately reachable on SMB (port 445) from the cloud VM**. With allow-all, exposure
grows silently with every device you add.

31. **Tag the nodes** in the admin console (Machines → ⋯ → *Edit ACL tags*). Doing it from
    the console means no node has to re-authenticate. Tagged nodes stop being "your" devices
    and are governed only by tag rules; their key expiry is disabled automatically.

    | Node | Tag | May reach |
    |---|---|---|
    | Cloud VM | `tag:plex-proxy` | Plex host **port 32400 only** |
    | Plex host | `tag:plex-server` | VM port 22 (only if you run the monitoring in Phase 11) |
    | Your admin laptop/phone | *untagged* (listed by name) | Everything |

    Keep personal devices **untagged**. Tagging a phone or laptop breaks Taildrop for it.

32. Start from [examples/tailscale-acl.hujson](examples/tailscale-acl.hujson). Fill in the
    `hosts` block with your tailnet IPs and paste it into **Access controls** in the admin
    console. The `tests` block runs on every save and **refuses the save if a test fails**.
    That's your safety net. Keep it, and add a test whenever you add a rule.

33. Verify from the VM:

    ```bash
    nc -vz -w 3 100.64.0.10 32400   # expect: succeeded
    nc -vz -w 3 100.64.0.10 22      # expect: timeout (blocked)
    ```

Design choices in the example policy, and why:

- **Admin devices are listed explicitly instead of using `autogroup:member`.** With
  `autogroup:member → *:*`, every *new* device you approve instantly reaches everything,
  and your only protection is remembering to restrict it afterwards. With an explicit list,
  a new device gets nothing until you add it on purpose. Forgetting costs you a connection
  error you notice right away, not silent exposure.
- **Explicit names are tied to tailnet IPs**, and those are bound to node keys, so this is
  real authentication. If you delete and re-add a device it gets a new IP. Update `hosts`.
- **A broken policy is easy to fix.** The admin console is on the public web and needs no
  tailnet access, and LAN access never goes through ACLs. Default-deny is safe to adopt.
- **Expect the VM to still *see* all peers** in `tailscale status`. Visibility follows who
  may connect *to* a node, so peers allowed to reach the VM are still listed. It can list
  them; it can't connect to them.

If your Plex host uses a **subnet router** instead of running Tailscale itself (see
[section 6](#6-tailscale-on-common-plex-hosts)), the destination is the Plex host's **LAN IP**:
`"dst": ["<plex-lan-ip>:32400"]`, and the route must be approved (or covered by
`autoApprovers`).

### Phase 10: Harden the VM

34. **Close public SSH.** Once you can `ssh ubuntu@100.64.0.20` over the tailnet:

    ```bash
    # delete any public port 22 accept rule, then:
    sudo netfilter-persistent save
    ```

    Then **delete the TCP 22 ingress rule from the OCI Security List** so the packet dies at
    Oracle's edge. Tailnet SSH keeps working because Tailscale's own `ts-input` chain sits
    first in INPUT and accepts traffic arriving on `tailscale0`.
    - Use the firewall, not `ListenAddress` in `sshd_config`. sshd can start before
      `tailscale0` has an address and then fail to bind.
    - **Never remove UDP 41641.** Removing the public SSH rule can't lock you out; removing
      the Tailscale port can. The serial console is your break-glass either way.
    - Geo filtering is not an SSH access control. In the build this repo came from, one
      week of logs showed hundreds of failed SSH logins from inside the allowed countries.
35. **sshd**: `/etc/ssh/sshd_config.d/99-hardening.conf`:

    ```
    PermitRootLogin no
    AllowUsers ubuntu
    MaxAuthTries 3
    PasswordAuthentication no
    ```

    `sudo sshd -t && sudo systemctl reload ssh`. Note the image also has an `opc` user;
    `AllowUsers` blocks it.
36. **Automatic patching with reboots.** `unattended-upgrades` is on by default, but
    `Automatic-Reboot` is off, so kernel fixes install and then never run. Add
    `/etc/apt/apt.conf.d/52unattended-upgrades-local`:

    ```
    Unattended-Upgrade::Automatic-Reboot "true";
    Unattended-Upgrade::Automatic-Reboot-Time "02:30";
    ```

    Cost: a ~30-second blip on nights a kernel update lands. Do the reboot test in Phase 6
    first, so you know everything comes back unattended.
37. ⚠️ **Caddy and Tailscale do not auto-update.** `unattended-upgrades` only takes Ubuntu's
    own origins by default, and these two come from third-party repositories. So the
    internet-facing TLS server and the daemon holding your tailnet key never update on their
    own. Pick one:
    - Add their origins to `Unattended-Upgrade::Origins-Pattern`. Check the exact origin
      strings with `apt-cache policy caddy tailscale` first.
    - Or monitor them and upgrade by hand (Phase 11).

    When upgrading by hand **over tailnet SSH**, run it inside `screen` or `tmux`. The
    Tailscale package restarts `tailscaled`, which drops your SSH session mid-upgrade:

    ```bash
    screen -dmS patch bash -c 'sudo apt-get update && sudo apt-get -y dist-upgrade > /tmp/patch.log 2>&1; echo EXIT=$? >> /tmp/patch.log'
    ```

    Ignore any "security update available with ESM Apps" note about `caddy`: that's Ubuntu's
    old 2.6.x build, and you're already running a much newer one from Caddy's repo.

### Phase 11: Monitoring

38. **Run the health check somewhere other than the VM.** A box can't report its own death.
    The Plex host is the natural place: it probes the public URL exactly the way a viewer
    does (out your home internet, to the VM, through Caddy, back over the tunnel), so one
    request covers stale DNS, the VM being down, Caddy down, the tunnel down, an expired
    Tailscale key, and a bad certificate.

    [scripts/plex-proxy-watchdog.sh](scripts/plex-proxy-watchdog.sh) does three checks:
    `/identity` returns a `machineIdentifier`; certificate days remaining (warns under 14,
    which catches silent renewal failures); the VM's tailnet peer is online. It alerts after
    2 consecutive failures, repeats at most every 6 hours, and sends a recovery message.
    It needs only bash, curl, openssl and GNU date, so it runs on any Linux box, NAS, or
    Raspberry Pi.

    ```bash
    cp scripts/plex-proxy-watchdog.env.example ~/.plex-proxy-watchdog.env && chmod 600 ~/.plex-proxy-watchdog.env
    cp scripts/notify-examples.sh ~/bin/notify.sh && chmod 700 ~/bin/notify.sh   # keep one backend
    ./scripts/plex-proxy-watchdog.sh --test      # confirm a notification arrives
    DRY_RUN=1 ./scripts/plex-proxy-watchdog.sh && ./scripts/plex-proxy-watchdog.sh --status
    ```

    Then cron it every 5 minutes:

    ```
    */5 * * * * /path/to/plex-proxy-watchdog.sh
    ```

    `NOTIFY_CMD` is any command that takes a subject and a body;
    [scripts/notify-examples.sh](scripts/notify-examples.sh) has ntfy, Telegram, Pushover and
    SMTP versions.

    What it can't see: a Synology Tailscale package that has fallen back to userspace mode
    (see [section 6](#synology-nas-plex-package-or-plex-in-container-manager)). Everything
    still answers, just slower. On a NAS, add `ip link show tailscale0` as a separate check.

39. **Patch monitoring (recommended).** Daily: SSH to the VM over the tailnet and check pending
    updates, whether a reboot is overdue, and whether `caddy`/`tailscale` are behind their
    candidate versions. This needs the `tag:plex-server → tag:plex-proxy:22` rule in the
    example ACL, and it doubles as a check that your admin SSH path still works after
    unattended reboots.

40. **Weekly glance:** OCI egress (Observability → Metrics) against the 10 TB allowance, and
    actual spend in Cost Analysis.

---

## 6. Tailscale on common Plex hosts

The goal in every case is the same: the VM needs to reach `<something>:32400` over the
tailnet, ideally on a **direct** path.

| Plex runs on | Recommended approach | Caddy upstream |
|---|---|---|
| Linux, bare metal | Tailscale on the host | `<host-tailnet-ip>:32400` |
| Windows / macOS | Tailscale on the host | `<host-tailnet-ip>:32400` |
| Linux VM (Proxmox, ESXi, Hyper-V) | Tailscale **inside the VM** | `<vm-tailnet-ip>:32400` |
| LXC container (Proxmox) | Tailscale inside the CT (needs `/dev/net/tun`) | `<ct-tailnet-ip>:32400` |
| Docker on Linux | Tailscale on the Docker host, Plex in `network_mode: host` | `<host-tailnet-ip>:32400` |
| Docker, no host access | Tailscale **sidecar** container | `<sidecar-tailnet-ip>:32400` |
| Synology (Plex package or container) | Synology Tailscale package, **kernel mode** | `<nas-tailnet-ip>:32400` |
| Unraid | Tailscale plugin on the host | `<server-tailnet-ip>:32400` |
| TrueNAS SCALE | Tailscale app with host networking | `<nas-tailnet-ip>:32400` |
| Anything else / can't install | **Subnet router** on another LAN machine | `<plex-lan-ip>:32400` |

### Standalone Linux host

```bash
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up --hostname=plex-server
```

Plex listens on all interfaces by default, so `<tailnet-ip>:32400` works immediately. If you
run a host firewall (ufw/firewalld), allow TCP 32400 on the `tailscale0` interface.

### Windows or macOS

Install the Tailscale client, sign in, and disable key expiry for the device. On Windows,
make sure Windows Defender Firewall allows Plex Media Server inbound on the Tailscale
interface. The Tailscale adapter is often classed as a *Public* network, and the Plex
installer's rule may only cover *Private*. Run Tailscale as a service (unattended mode) so the
tunnel is up before anyone logs in.

### Virtual machine (Proxmox, ESXi, Hyper-V)

Install Tailscale **inside the Plex VM**, exactly as for a standalone host. Avoid putting it
on the hypervisor and routing into the VM: that's more moving parts, and the ACL then has to
reason about LAN addresses.

### LXC container (Proxmox)

Unprivileged containers need the TUN device passed through. On the Proxmox host, add to
`/etc/pve/lxc/<id>.conf`:

```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```

Restart the container, then install Tailscale inside it as for any Linux host. Without TUN,
Tailscale falls back to userspace networking (see the Synology section for why that's bad).

### Docker on a Linux host

Simplest: install Tailscale on the **Docker host** and run Plex with `network_mode: host`
(Plex's own recommendation anyway). The host's tailnet IP then serves 32400.

If Plex is in bridge mode with `-p 32400:32400`, that also works: the published port is
reachable on the host's tailnet IP.

### Docker sidecar (no access to the host)

Run Tailscale as its own container and attach Plex to its network namespace:

```yaml
services:
  tailscale:
    image: tailscale/tailscale:stable
    hostname: plex-server
    environment:
      - TS_AUTHKEY=${TS_AUTHKEY}        # a tagged, reusable-false auth key
      - TS_STATE_DIR=/var/lib/tailscale
      - TS_USERSPACE=false
    volumes:
      - ./tailscale-state:/var/lib/tailscale
    devices:
      - /dev/net/tun:/dev/net/tun
    cap_add: [NET_ADMIN, NET_RAW]
    restart: unless-stopped

  plex:
    image: plexinc/pms-docker:latest
    network_mode: service:tailscale   # Plex shares the sidecar's network
    depends_on: [tailscale]
    # ...your usual volumes/env
```

Trade-off: Plex now lives only in the sidecar's namespace, so LAN clients reach it only if
you also publish 32400 on the `tailscale` service. Use this only if host networking isn't
available.

### Synology NAS (Plex package or Plex in Container Manager)

1. Install **Tailscale** from Package Center and sign in.
2. **Make it run in kernel mode.** By default the DSM package can run in *userspace
   networking* mode, with no `tailscale0` interface. It still works, but every byte goes
   through a slow userspace path, which hurts video throughput. Enable kernel mode over SSH
   (DSM 7):

   ```bash
   sudo /var/packages/Tailscale/target/bin/tailscale configure-host
   sudo synosystemctl restart pkgctl-Tailscale
   ip link show tailscale0          # must exist and be UP
   ```

3. ⚠️ **Re-check after every Tailscale package update.** Package auto-updates replace the
   binary and can drop the capabilities that kernel mode needs. It then falls back to
   userspace **silently**: Plex still answers, the watchdog stays green, and only throughput
   degrades. Either re-run step 2 after updates, or add a cron check that alerts when
   `tailscale0` disappears.
4. **Plex as the Synology package** listens on the NAS directly, so use the NAS's tailnet IP.
   **Plex in Container Manager**: use `network_mode: host` (or publish 32400), and the NAS's
   tailnet IP works the same way.
5. The `tailscale` CLI lives at `/var/packages/Tailscale/target/bin/tailscale` and is not on
   the PATH for cron jobs. Use the full path in scripts.
6. Disable key expiry for the NAS. If the NAS is also your backup or remote-admin path, an
   expired key takes all of those down at once, together with Plex.

### Unraid

Install the **Tailscale** plugin (Community Applications), sign in, disable key expiry. Plex
containers on Unraid normally use `host` networking, so the server's tailnet IP serves 32400.
If Plex is on a custom `br0` network with its own LAN IP, use a subnet route to that IP
instead, or move Plex to host networking.

### TrueNAS SCALE

Install the **Tailscale** app with host networking enabled, sign in with an auth key, and
disable key expiry. Point Caddy at the NAS's tailnet IP.

### Subnet router (when you can't install Tailscale on the Plex host)

Run Tailscale on any always-on Linux machine on the same LAN, and advertise **only the Plex
host's address**, not your whole LAN:

```bash
sudo tailscale up --advertise-routes=<plex-lan-ip>/32
```

Approve the route in the admin console. Point Caddy at `<plex-lan-ip>:32400`, and use that
LAN IP as the ACL destination. Advertising a `/32` keeps the proxy's reach to one host even if
the ACL is later loosened.

---

## 7. Verification checklist

Run after the build, after any change, and after the VM reboots.

| Check | Command (where) | Expect |
|---|---|---|
| Public HTTPS | `curl -s -o /dev/null -w '%{http_code}' https://plex.example.com/identity` (outside) | `200` |
| HTTP redirects | `curl -sI http://plex.example.com` (outside) | `308` to https |
| Certificate | `echo \| openssl s_client -connect plex.example.com:443 -servername plex.example.com 2>/dev/null \| openssl x509 -noout -enddate` | > 14 days out |
| Tunnel is direct | `tailscale ping -c 8 100.64.0.10` (VM) | last pongs `via <ip>:<port>`, not DERP |
| ACL holds | `nc -vz -w 3 100.64.0.10 22` (VM) | blocked |
| Public SSH closed | `nc -vz -w 5 203.0.113.10 22` (outside) | closed/filtered |
| Geo set loaded | `sudo ipset list geo_allow \| grep 'Number of entries'` (VM) | tens of thousands |
| Services | `systemctl is-active caddy tailscaled ssh netfilter-persistent` (VM) | all `active` |
| Old forward closed | `nc -vz -w 5 <home-wan-ip> 32400` (VM) | closed/filtered |
| Real stream | Play from a phone on cellular; check Caddy log | `/library/parts/` requests |

---

## 8. Troubleshooting and gotchas

Every item here cost real time on the original build.

### F1: Tailscale is on DERP, and nothing looks broken

**Symptom:** everything returns 200 but streams are slower than they should be.
`tailscale status` shows `relay "xxx"` and `tailscale ping` says `via DERP`.
**Cause:** UDP 41641 isn't open on the VM, in the cloud security list *or* the host
iptables. Your home side is behind NAT, so the VM must be the reachable end.
**Fix:** open UDP 41641 in both places. The path flips to direct within seconds.

### F2: Never geo-filter port 80

Let's Encrypt validates HTTP-01 challenges from **several vantage points on different
continents**, on purpose, and doesn't publish a fixed IP list. Restrict port 80 by country
and renewals start failing. Nothing breaks until the certificate expires about 60 days later.
Keep port 80 open to the world. It serves only the ACME challenge and a redirect to HTTPS.
(If you really need port 80 closed, switch Caddy to a DNS-01 challenge with your DNS provider's
plugin.)

### F3: `ipset` silently truncates at 65,536 entries

Large countries exceed the default `maxelem`. Create the set with `maxelem 300000`, as the
script does.

### F4: Rules after Oracle's REJECT never match

The stock INPUT chain ends in `REJECT --reject-with icmp-host-prohibited`. Always
`iptables -L INPUT -n --line-numbers` and insert *above* it.

### F5: `allowedNetworks` vs LAN Networks

Covered in [Phase 7](#phase-7-plex-settings). The *"allowed without auth"* list bypasses login.
Never add the VM's tailnet IP or a `100.64.0.0/10` range.

### F6: You can't test the public URL from the VM itself

Two traps that both look like an outage:
1. With geo filtering, the VM's own public IP isn't in the allowlist, so `curl https://plex.example.com`
   from the VM is rejected (`HTTP 000`).
2. `curl -k https://127.0.0.1/` sends no SNI, so Caddy refuses the TLS handshake.

Correct local test:
`curl --resolve plex.example.com:443:127.0.0.1 https://plex.example.com/identity`.

### F7: "It works on Wi-Fi" proves nothing

On your home Wi-Fi, Plex connects directly to the LAN address. Test on cellular or from
another network, and confirm the request shows up in Caddy's access log.

### F8: A remote client is stuck at low quality

Check the **client app's** remote/cellular quality setting before touching the server. Reading
the Caddy log: many small `transcode/universal/session` requests at a steady pace means a
transcode. A few large `/library/parts/` range requests means Direct Play. Caddy logs a request
when it *completes*, so a Direct Play stream in progress can look idle.

### F9: One mobile carrier is very slow to the VM

On the original build, one US mobile carrier reached the VM at ~3.6 Mbps while reaching other
servers in the same city at 250+ Mbps. Another carrier had no problem. The leading theory: the
carrier is IPv6-only on the phone and reaches IPv4-only hosts through shared NAT64 gateways.
It cleared up on its own the next day. If it persists for you, add IPv6 to the VM: an AAAA
record (also grey cloud), plus `ip6tables` rules and a second `family inet6` ipset. Otherwise
the v6 path has no geo filter. To measure a client's raw throughput to the VM without Plex
involved, temporarily serve a 50 MB test file from Caddy.

### F10: Tailscale on the phone doesn't speed this up

A common tip is to put Tailscale on your phone and connect to the server's tailnet IP directly.
On mobile carriers with symmetric carrier-grade NAT, the direct path can't be established, so
traffic falls back to a DERP relay (100–450 ms, versus ~30 ms through the VM). Plex also
prefers the HTTPS custom URL over a plain-HTTP tailnet URL, and adding the extra URL made the
app slower to connect. Keep Tailscale on your phone for admin access; don't use it as a Plex
fast lane.

### F11: Cloudflare record flips to orange on its own

A dynamic-DNS updater managing the record is re-sending `proxied: true`. Remove the record from
the updater and manage it by hand.

### F12: Monitoring script raises false alarms now and then

If you write your own checks in bash: `set -o pipefail` + `printf "$body" | grep -q pattern`
fails *when the match succeeds*, because `grep -q` exits early and `printf` dies of SIGPIPE.
It only happens when the response is larger than the pipe buffer, so it looks random. Use
`[[ "$body" == *pattern* ]]` instead.

### F13: A check that "passed" because it failed

Two false all-clears from the original build:
- `grep 'dport 22' /etc/iptables/rules.v4 || echo "no public SSH rule"` ran **without sudo**,
  got *Permission denied*, and printed the reassuring branch.
- `docker exec plex ps aux | grep Transcoder` returned nothing, read as "Direct Play". In
  fact `docker` wasn't on the non-interactive PATH, and the server was transcoding the
  whole time.

When a verification command returns *nothing*, confirm it actually ran. Use `sudo` where
needed, full binary paths in cron and over SSH, and don't hide stderr with `2>/dev/null`
while verifying.

### F14: How many viewers can it handle?

The tunnel was measured at ~118 Mbps home→VM and the VM at 300+ Mbps to viewers. In
practice your **Plex server's transcode capacity** runs out long before the network does.
Direct Play streams cost almost nothing; each transcode costs a GPU or CPU slot. Getting
remote clients to Direct Play (see F8) matters more than any proxy tuning.

---

## 9. Maintenance

| When | What |
|---|---|
| Automatic, nightly | Ubuntu security updates + reboot at 02:30 (Phase 10) |
| Weekly / on alert | `caddy` and `tailscale` versions (they don't auto-update) |
| After a Tailscale update on a NAS | Confirm `tailscale0` exists (kernel mode) |
| Kernel moves to a new series (HWE) | `unattended-upgrades` only takes `-security`; run a `dist-upgrade` inside `screen`, then reboot. Old kernels stay installed as GRUB fallbacks |
| If you monitor "running kernel ≠ newest installed" | Give it ~26 h of grace. `unattended-upgrades` installs in the morning and reboots at the *next* 02:30 window, so an instant check alerts falsely every time |
| Adding a tailnet device | It gets nothing until you add it to the ACL `hosts` and the admin rule |
| Monthly | OCI egress and spend |
| Before travel | Is your destination in the geo allowlist, or will your devices use Tailscale? |

---

## 10. Rollback

Nothing here touches your library or Plex database.

1. Re-enable the router port forward (you kept it disabled, not deleted).
2. Restore `Preferences.xml` from the Phase 7 backup, or in the UI: re-enable **Remote
   Access** and clear **Custom server access URLs**.
3. Delete the `plex` DNS record.
4. Optional: terminate the VM. Release the reserved IP if you won't rebuild.
5. Optional: remove the VM from your tailnet, and its rules from the ACL.

---

## 11. Files in this repo

| File | Runs on | Purpose |
|---|---|---|
| [AGENT_PROMPT.md](AGENT_PROMPT.md) | Your coding agent | A prompt to have an AI agent guide you through this build |
| [examples/Caddyfile](examples/Caddyfile) | VM | Reverse proxy config |
| [examples/tailscale-acl.hujson](examples/tailscale-acl.hujson) | Tailscale admin console | Least-privilege tailnet policy with tests |
| [scripts/geo-allow-refresh.sh](scripts/geo-allow-refresh.sh) | VM (root, daily cron) | Builds the country allowlist ipset |
| [scripts/plex-proxy-watchdog.sh](scripts/plex-proxy-watchdog.sh) | Plex host or any box *other than* the VM | Health check with throttled alerts |
| [scripts/plex-proxy-watchdog.env.example](scripts/plex-proxy-watchdog.env.example) | same | Watchdog config template |
| [scripts/notify-examples.sh](scripts/notify-examples.sh) | same | Notifier backends: ntfy, Telegram, Pushover, SMTP |

Contributions and corrections are welcome. Open an issue or a pull request.
