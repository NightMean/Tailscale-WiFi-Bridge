# AGENTS.md

## Project

A PowerShell automation script (`Tailscale-WiFi-Bridge.ps1`) that turns a Windows 10/11 PC into an ad-hoc Wi-Fi Access Point and transparent L3 NAT gateway. Connected client devices (e.g., Smart TVs, consoles, IoT, guest phones) gain direct access to the private Tailscale network (Tailnet), local LAN, and the Internet without needing Tailscale installed on the client device.

Key file:
- `Tailscale-WiFi-Bridge.ps1` — WinRT tethering automation, WinNAT configuration, interface forwarding, and Windows Firewall orchestration.

## Commands

- Start bridge (interactive administrator prompt):
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Tailscale-WiFi-Bridge.ps1
  ```
- Run non-interactive / headless start:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Tailscale-WiFi-Bridge.ps1 -Start
  ```
- Stop bridge and teardown NAT/AP:
  ```powershell
  powershell -ExecutionPolicy Bypass -File .\Tailscale-WiFi-Bridge.ps1 -Stop
  ```

## Invariants & Design Principles

- **Elevation requirement:** Requires administrative privileges to configure WinNAT (`New-NetNat`), modify IP forwarding (`Set-NetIPInterface`), and toggle Windows Firewall rules.
- **Zero Tailscale Admin Approval:** Uses outbound NAT via the host PC's existing Tailscale identity; no `--advertise-routes` subnet routes need approval in the Tailscale admin console.
- **Clean teardown:** Always restore network adapter forwarding and remove transient NAT objects on stop to prevent network collisions.

## Repository policy

- Public repository (`NightMean/Tailscale-WiFi-Bridge`).
