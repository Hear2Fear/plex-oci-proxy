# Agent prompt: build a Plex cloud proxy with me

Paste everything in the box below into a coding agent that can run shell commands (Claude
Code, or similar) from a machine that can SSH to your servers. Clone this repo first so the
agent can read `README.md` and the example files.

```text
You are helping me build remote access to my Plex Media Server through a small cloud VM,
following the runbook in README.md in this repository. Read README.md, examples/, and
scripts/ in full before doing anything else.

Goal: remote viewers reach Plex at an HTTPS hostname that points at a cloud VM. The VM runs
Caddy (TLS) and reaches my Plex server over Tailscale. My home router ends up with NO Plex
port forward and my home IP is not published anywhere.

## How to work with me
- Start by interviewing me. Ask these one or two at a time, not all at once:
  1. What does Plex run on? (bare metal Linux, Windows, macOS, VM, LXC, Docker,
     Synology, Unraid, TrueNAS, other) And can I install software on that host?
  2. Do I already use Tailscale? Is there an existing ACL policy?
  3. Which cloud provider and region? (Default: Oracle Cloud Always Free, nearest region.)
  4. My domain and DNS provider. If Cloudflare: is anything managing records automatically
     (a router DDNS client, for example)?
  5. Do I currently use Plex Remote Access and a router port forward? Is the forward
     restricted by country or source IP? Which countries do my viewers live in?
  6. How will I want alerts delivered? (ntfy, Telegram, Pushover, email, none)
- Then write a short plan listing which README phases apply to me and which section 6 recipe
  fits my Plex host. Wait for my OK.
- Work one phase at a time. At the end of each phase: show what changed, run that phase's
  verification, and tell me the result plainly before moving on.
- Restate where we are at the start of each reply, e.g. "Phase 4 of 11: Tailscale on the
  Plex host".

## Safety rules (do not skip)
- Before any change that could interrupt service or lock me out (firewall rules, sshd,
  Tailscale ACL, Plex network settings, router forward), tell me exactly what you will run,
  what could break, and the rollback. Wait for my yes.
- Take a backup before editing a config file (`cp file file.bak-$(date +%Y%m%d-%H%M%S)`).
- Build the new path alongside the existing one. Do not disable my router port forward or
  Plex Remote Access until the new URL works end to end from outside my network.
- Never add the VM's Tailscale IP, or any 100.64.0.0/10 range, to Plex's "allowed without
  auth" list (allowedNetworks). Every remote viewer appears as the VM's IP, so that would
  give the whole internet password-free access to my library.
- Never geo-filter port 80 on the VM (it breaks Let's Encrypt renewal). Never advertise an
  http:// URL to Plex.
- Never remove UDP 41641 from the VM's firewalls.
- If using Cloudflare DNS, the Plex record must be "DNS only" (grey cloud).
- Never print secrets (auth keys, tokens, passwords) back to me or write them into files
  tracked by git. Secrets go in files with mode 600 outside the repo.
- Things I must do myself, because they need a browser or my login: cloud sign-up and
  billing, Tailscale admin console (tags, key expiry, ACL paste), DNS records, Plex web UI
  settings. Give me exact click paths and the values to enter, then wait for me to confirm.

## Verification habits
- Test the public URL from outside the VM. From the VM itself, use
  `curl --resolve <host>:443:127.0.0.1 https://<host>/identity`.
- Confirm the Tailscale path is direct (`tailscale ping -c 8 <plex-tailnet-ip>`, last
  replies "via <ip>:<port>", not DERP).
- If a check returns nothing, confirm the command actually ran (sudo? on PATH? stderr
  hidden?) before treating it as a pass.
- "Works on Wi-Fi" proves nothing. Remote tests use a phone on cellular or another network.

## Done means
- README section 7 checklist all passes, and you show me the output.
- The tailnet ACL from examples/tailscale-acl.hujson (adapted to my devices) is applied,
  and its tests pass.
- Public SSH to the VM is closed; I can SSH to it over the tailnet.
- The watchdog runs every 5 minutes on a machine other than the VM, and a --test alert
  reached me.
- Finally, write me a one-page summary: hostnames, IPs, where each config file and script
  lives, the cron entries, and how to roll back.
```
