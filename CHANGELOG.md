# Changelog

## 3.0.1

Stable release of the redesigned Datafetch dashboard.

- Add outlined branding, a Klod Cripta frame caption, cold Nordic-inspired colors, field icons and adaptive panels with internal dividers.
- Replace repeated screen clearing with a renderer that updates changed rows in one output packet.
- Add CPU utilization history, root disk space, network rates, battery power/health and keyboard controls.
- Normalize desktop names, including KDE Plasma, while preserving unknown session identities.
- Show a SOFTWARE overview block and paginated details with shell, init, root filesystem, package managers, supported AUR helpers and running audio servers.
- List multiple supported AUR helpers with commas; display `non pervenuto` when none is found.
- Resolve GPUs through PCI/sysfs, revision-aware local databases and available driver model information. Preserve ambiguous families and numeric fallbacks; deduplicate PCI/DRM devices.
- Keep readings and controls accessible down to 48×16, including pause, resize, suspend/resume and terminal restoration.
- Provide snapshot, ASCII, color and icon controls without a Python or special-font runtime dependency.
- Add automated software/hardware fixtures and pseudo-terminal regression checks.

Old-netbook flicker and font rendering still need confirmation on real devices. Hardware-dependent fields remain `n/a` when unavailable.
