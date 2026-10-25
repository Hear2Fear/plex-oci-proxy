# Changelog

## 2026-10-24
- Initial public runbook: architecture, 11-phase build guide, Tailscale recipes for common
  Plex hosts, least-privilege tailnet ACL, geo-filter script, generic watchdog with
  notifier examples, and an agent prompt.

## 2026-10-24 (later)
- Added MIT LICENSE.

## 2026-10-24 (OCI detail)
- Phases 1-2 rewritten with exact OCI console click paths, verified against a live tenancy:
  sign-up fields, bypass codes, PAYG, budget, the 5-step Create instance wizard (default
  shape is not Always Free), reserved-IP swap, Default Security List rules, serial console.

## 2026-10-24 (Plex detail)
- Phase 7 rewritten with exact Plex Web labels (checked against a live server): settings
  file backup per platform, every Network field, Relay off, Remote Access off and its
  expected red warning, Preferences.xml key check, client quality paths, fuller rollback.

## 2026-10-24 (Tailscale + mobile data)
- Tailscale: account setup, admin console tour, Device management settings, auth-key
  options, exact Machines menu paths (key expiry, rename, IPv4, routes, ACL tags), all
  checked against a live admin console.
- Phase 9 reordered into three saves (tagOwners -> tag nodes -> full policy) so remote
  Plex never drops while tagging.
- New F9b: mobile data metering, video throttling, deprioritization, hotspot limits, and
  why carrier-cached services outperform a cloud-hosted server on cellular.
