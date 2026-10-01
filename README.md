# OpenLogi for Omarchy

![OpenLogi showing MX Keys Mini and MX Master 4](images/cover.webp)

Local plugin for OpenLogi 0.8.10: device status in Omarchy's bar and an Action Ring on a Wayland layer-shell surface. The OpenLogi agent still owns HID access, sessions, haptics, and action execution. The shell receives presentation data and sends hover, activate, or cancel commands over a private JSON Lines bridge.

## Install

Requires OpenLogi 0.8.10, a running Omarchy Shell, Rust 1.98.0, `flock`, `jq`, and OpenLogi's build dependencies. The initial build may take a while. Installation does not replace files in `/usr` or change `~/.config/openlogi/config.toml`.

```sh
bash scripts/build-openlogi.sh
bash scripts/install.sh
omarchy-shell alanfrigo.openlogi status
```

The build pins commit `19036d7fe86abe11cdb628da11ff89aa5fb7a204` and applies `patches/openlogi-0.8.10-external-overlay.patch`. Private binaries and upstream licenses live in `~/.local/share/omarchy-openlogi/0.8.10/bin/`; the plugin lives in `~/.config/omarchy/plugins/alanfrigo.openlogi/`. The user service and desktop launcher switch to the private binaries. `protocolReady: true` and `agentState: connected` confirm the bridge and agent; an empty device inventory is not an error. The **Logi** bar button opens OpenLogi, and its tooltip reports connection and device status. Configure the Action Ring button and slots in OpenLogi; this plugin does not remap buttons.

The ring appears on the cursor's monitor. Click a slot or use Tab and Enter/Space. Escape or clicking outside cancels. Activation reaches the agent only after the surface unmaps and previous focus is verified. If the monitor, workspace, or previous window disappears, the action is canceled. The bridge and bar can report status even when no ring is open.

## Uninstall

```sh
bash scripts/uninstall.sh
```

Disables the plugin and restores the previous service and desktop launcher. OpenLogi device configuration stays unchanged. Private binaries are removed only if they match the installation receipt; modified files are preserved, and removal stops on conflicts. The receipt lives at `~/.local/state/omarchy-openlogi/install/`. Installation and removal lock the owned state directory without writing a lock file. If installation fails, inspect the error and receipt before retrying; do not delete receipt files manually.

Local checks: `node check.mjs`, `bash tests/install-lock.sh`, `omarchy plugin validate .`, and `bash -n scripts/*.sh`. `scripts/build-openlogi.sh` runs the Rust tests. Exercising a hardware action requires a configured button and a connected device; protocol tests do not replace that physical check.
