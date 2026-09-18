# Datafetch

A small Bash dashboard for Linux: the machine's identity at the top, live readings underneath.

**3.0 preview** brings a new terminal layout, updates only changed rows, and adds disk space, network traffic, battery information and keyboard controls. This branch is available for testing before a stable release.

## Try it

Download `datafetch.sh` from this branch and run:

```bash
bash datafetch.sh
```

No installation or root access is needed. Datafetch reads local system information. It does not make network requests or change system settings. On exit it restores the terminal and its previous screen.

## What's on screen

- Distribution, hostname, kernel, desktop, display session, CPU, GPU and core/thread counts.
- CPU usage, CPU0 frequency when available, CPU temperature and the highest temperature seen during the session.
- RAM and swap usage, with explicit units. Disabled swap is shown as disabled.
- Root filesystem usage and available space; these readings refresh every five seconds.
- Current receive/transmit rates on the default network interface. Rates use the actual elapsed time between samples. Interface changes and counter resets start a fresh sample.
- The first present system battery, identified by name: charge, charging state, power and health when the hardware exposes them. Peripheral batteries are excluded.
- A small CPU history on taller terminals: the last 40 samples, not a fixed time window.

Press `d` for package counts, shell, init system, audio server, root filesystem, CPU driver/governor and energy preference. Arch systems list every supported AUR helper found: `paru`, `yay`, `pikaur`, `aura`, `trizen`, `pakku`. Portage and a running OpenRC environment are also detected.

Missing readings are shown as `n/a`. Temperature detection uses CPU sensors, preferring Tdie over an offset Tctl when both exist. It does not use a disk temperature as a substitute. GPU names come from PCI information; Datafetch does not guess integrated/dedicated status from the vendor.

## Controls

| Key | Action |
| --- | --- |
| `p` or Space | Pause/resume the readings |
| `+` / `-` | Faster/slower refresh: 0.5, 1, 2, 5 or 10 seconds |
| `d` | Toggle system details |
| `q`, Ctrl+C or Ctrl+D | Exit |

The regular layout fits an 80×24 terminal. Smaller windows automatically use a compact layout, down to 48×16. Long fields end with `~` when shortened to fit. Resize handling continues to work while paused.

## Options

```bash
bash datafetch.sh --once
bash datafetch.sh --interval 2
bash datafetch.sh --compact
bash datafetch.sh --details
bash datafetch.sh --interface wlan0
bash datafetch.sh --once --width 120
bash datafetch.sh --ascii --no-color
```

`--once` prints one snapshot and exits. Redirecting or piping output selects this mode automatically, without terminal control sequences:

```bash
bash datafetch.sh > system.txt
```

`--interval` accepts values from 0.5 to 10 seconds. `--width` accepts 48 to 160 columns. Colors follow `NO_COLOR`; `--color always` and `--color never` override automatic selection. `--ascii` replaces decorative Unicode characters for terminals or fonts that need it. Use `--help` for the full list.

## Requirements

Bash 4.3 or later on Linux, with `/proc`, `/sys` and the usual command-line utilities (`awk`, `df`, `stty`, `uname`, `ps`, `sleep`, `wc`, `locale`, `readlink`).

`lscpu`, `lspci`, `pgrep`, package managers and Flatpak are optional; they add information when installed. Python, a special font and a graphical desktop are not required to run Datafetch.

## Development

Run the regression suite with Python 3 on Linux:

```bash
bash -n datafetch.sh
python3 -m unittest discover -s tests -v
```

Tests cover CLI behavior, CPU/memory calculations, sensor selection, battery units, network rates and a real pseudo-terminal for redraws, pause, resize and terminal restoration. They do not change system settings outside their own pseudo-terminal. Hardware fixtures supplement the devices available in the test environment.

## Italiano

Datafetch raccoglie le informazioni del computer e le affianca a un monitor aggiornato in tempo reale. Questa è la preview della versione 3.0, pronta da provare prima della release stabile.

Scarica `datafetch.sh`, apri il terminale nella cartella del file ed esegui `bash datafetch.sh`. Premi `p` per mettere in pausa, `+` e `-` per cambiare la frequenza, `d` per i dettagli, `q` per uscire. Non serve `sudo`.

La nuova interfaccia aggiunge spazio disco, traffico di rete e batteria. Le righe vengono aggiornate sul posto, senza cancellare tutta la schermata a ogni ciclo. Il formato si adatta alla finestra, fino a 48×16 caratteri. Con `--once` puoi ottenere una schermata di testo da copiare o salvare.

Le informazioni su temperatura, frequenza e batteria dipendono da ciò che il sistema rende disponibile. `n/a` indica un dato non leggibile. La batteria mostrata è la prima batteria di sistema presente; il nome aiuta a riconoscerla sui portatili che ne hanno più di una.

## License

[MIT](LICENSE) — Klod Cripta.
