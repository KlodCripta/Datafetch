# Datafetch 3.0.1

A small Bash dashboard for Linux: system information and live readings in a clean, adaptive terminal interface.

Datafetch combines an outlined title, light panel borders and a cold palette inspired by [Nord](https://www.nordtheme.com/docs/colors-and-palettes). Cyan, blue, violet and pine accents distinguish groups; small Unicode icons identify the fields. True color, 256-color and basic ANSI terminals are supported, with an ASCII mode and no special font requirement.

## Run

Download `datafetch.sh` and start it from the download directory:

```bash
bash datafetch.sh
```

No installation or root access is needed. Datafetch reads local system information without making network requests or changing system settings. On exit it restores the terminal and its previous screen.

## System and software

- Distribution, hostname, kernel, CPU, GPU, core/thread counts and uptime.
- Desktop/session names such as **KDE Plasma**, **GNOME**, **LXQt**, **Cinnamon**, **Xfce** and **MATE**. Known session aliases are normalized; unrecognized names are retained.
- A **SOFTWARE** block in the overview when space permits: package managers, AUR helpers, shell, init system, root filesystem and audio server.
- AUR helper detection for `paru`, `yay`, `pikaur`, `aura`, `trizen` and `pakku`. Multiple matches appear separated by commas, for example `paru, pikaur`. No supported helper found: `non pervenuto`.
- Native package tools: pacman, apt/dpkg, Portage, dnf/dnf5, zypper, yum/rpm, xbps and apk. Available Flatpak, Snap, Nix and Guix commands are listed alongside the native tool. Package counts use the supported local package database; a failed query is shown as `n/a`.
- The launching shell is read from the parent process chain, falling back to `$SHELL`; the Bash interpreter used by Datafetch is not automatically presented as the user's shell.
- The init field reports PID 1, or OpenRC when its running environment is detected. The filesystem field refers to `/`.
- Audio detection checks the current user's running PipeWire, PulseAudio and JACK processes. It does not start an audio service; missing readings are `n/a`.

Press **d** for package counts, full software lists, CPU driver/governor/energy preference and GPU details. If the terminal is too small to show every detail, the title displays a page number and **d** advances through the pages, then returns to the overview. Live readings and exit controls remain visible. Long lists wrap in the details view.

## Live readings

- CPU utilization and the current frequency reported for CPU0.
- CPU temperature and the highest temperature seen during this session. CPU sensors are selected explicitly; disk temperatures are not substituted. Tdie is preferred over an offset Tctl when available.
- RAM and swap usage with explicit units; disabled swap is labeled.
- Root filesystem usage and free space, refreshed every five seconds.
- Receive/transmit rates on the default or selected network interface, calculated from actual elapsed time. Counter resets and interface changes start a fresh sample.
- The first present system battery: charge, charging state, power and health when exposed by the hardware. Peripheral batteries are excluded.
- A CPU utilization chart on taller terminals, labeled `CPU USAGE`, with a 0–100% scale and the number of displayed samples. It holds up to 40 samples that fit, not a fixed time window.

Only changed rows are redrawn, in a single output packet. Static device and software discovery runs once at startup. Refresh does not repeatedly clear the screen.

## GPU detection

Datafetch reads the [kernel's PCI identifiers and revision](https://docs.kernel.org/PCI/sysfs-pci.html), machine-readable `lspci` output when installed, and local `pci.ids`/`amdgpu.ids` databases. Exact AMD device/revision matches can resolve names such as `AMD Radeon Vega 8 (Picasso)`. Conflicting or generic database matches retain the more informative PCI family.

The NVIDIA driver's per-device model and an optional sysfs product name are used when available. An AMD codename such as `Barcelo` is retained when it is the best identification available. It is not automatically relabeled `Vega 7`, and no GPU model is inferred from the CPU name. Unknown models retain vendor/device IDs.

Multiple GPUs are supported. A device listed by both PCI and DRM appears once; the boot display is shown first when the kernel identifies it. This order does not indicate which GPU is currently rendering an application.

## Controls

| Key | Action |
| --- | --- |
| `p` or Space | Pause/resume readings |
| `+` / `-` | Faster/slower refresh: 0.5, 1, 2, 5 or 10 seconds |
| `d` | Open details, advance pages, then return to overview |
| `q`, Ctrl+C or Ctrl+D | Exit |

The regular layout fits 80×24. Windows at least 104 columns wide and 20 rows tall show panels side by side; narrower windows stack them. The compact layout works down to 48×16. The overview's SOFTWARE block appears when it fits, and is always available through the details pages. Long overview values end with `~` when shortened. Resizing works while paused; Ctrl+Z and foreground resume restore the terminal correctly.

## Options

```bash
bash datafetch.sh --once
bash datafetch.sh --interval 2
bash datafetch.sh --compact
bash datafetch.sh --details
bash datafetch.sh --interface wlan0
bash datafetch.sh --once --width 120
bash datafetch.sh --no-icons
bash datafetch.sh --ascii --no-color
```

`--once` prints a snapshot and exits. Redirecting or piping output selects this mode automatically, without terminal control sequences:

```bash
bash datafetch.sh > system.txt
```

`--interval` accepts 0.5–10 seconds; `--width` accepts 48–160 columns. `--no-icons` hides symbols while keeping the frame style. `--ascii` and non-UTF-8 locales disable decorative Unicode. Colors follow `NO_COLOR`; `--color always` and `--color never` override automatic selection. Use `--help` for all options.

## Requirements and verification

Bash 4.3 or later on Linux, with `/proc`, `/sys` and standard utilities (`awk`, `df`, `stty`, `uname`, `ps`, `sleep`, `wc`, `locale`, `readlink`). Python, a graphical desktop and special fonts are not runtime requirements.

`lscpu`, `lspci`, `pgrep`, package tools and Flatpak are optional. Local `pci.ids` (usually from hwdata/pciutils) and `amdgpu.ids` (libdrm) improve GPU names. Missing databases still allow numeric PCI identification.

Run the development tests with Python 3:

```bash
bash -n datafetch.sh
python3 -m unittest discover -s tests -v
```

Tests cover desktop/software and GPU fixtures, sensor calculations, framed layouts, details pagination and a real pseudo-terminal for refresh, pause, resizing, suspend/resume and cleanup. They do not change system settings outside their own pseudo-terminal. Tests cannot reproduce every terminal, font or device: flicker and rendering cost on very old netbooks still need confirmation on those machines.

## Italiano

**Datafetch 3.0.1** affianca le informazioni del computer a un monitor aggiornato in tempo reale. Mantiene un titolo a contorno, la firma Klod Cripta nella cornice, colori freddi e piccole icone senza richiedere font speciali.

Scarica `datafetch.sh` e avvialo con `bash datafetch.sh`. Non serve `sudo`. Premi `p` per mettere in pausa, `+` e `-` per cambiare la frequenza, `d` per i dettagli e le pagine successive, `q` per uscire.

Il blocco **SOFTWARE** mostra gestori dei pacchetti, helper AUR, shell, init, filesystem della radice e server audio. Compare nella schermata principale quando c'è spazio; i dati sono consultabili con `d` anche sui terminali piccoli. Gli helper vengono separati da virgole (`paru, pikaur`); se nessuno di quelli supportati viene trovato, appare `non pervenuto`.

I nomi dei desktop sono normalizzati: KDE diventa **KDE Plasma**, mentre GNOME, LXQt, Cinnamon e gli altri mantengono il proprio nome. CPU, GPU e sensori vengono letti dai dati disponibili sul sistema, senza adattamenti al computer dell'autore. Il nome della GPU resta prudente quando gli identificativi non permettono di distinguere un modello preciso.

Con `--once` ottieni una schermata da copiare o salvare; con `--no-icons` nascondi le icone; con `--ascii --no-color` usi la modalità essenziale. Le righe vengono aggiornate sul posto, senza cancellare tutta la schermata a ogni ciclo. `n/a` indica un dato non disponibile. La prova sui vecchi netbook resta utile per verificare lo sfarfallio sull'hardware reale.

## License

[MIT](LICENSE) — Klod Cripta.
