#!/usr/bin/env python3
"""Behavior tests: CLI contracts, real terminal lifecycle and sensor fixtures."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'datafetch.sh'
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


class Terminal:
    def __init__(self, cols=80, rows=24, args=()):
        self.master, self.slave = pty.openpty()
        self.before = termios.tcgetattr(self.slave)
        self.resize(cols, rows, notify=False)
        self.process = subprocess.Popen(
            ['bash', str(SCRIPT), *args], stdin=self.slave,
            stdout=self.slave, stderr=self.slave,
            env={**os.environ, 'TERM': 'xterm-256color'}, start_new_session=True)
        self.output = b''

    def resize(self, cols, rows, notify=True):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
        if notify:
            os.kill(self.process.pid, signal.SIGWINCH)

    def read(self, seconds=.3):
        result = b''
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if select.select([self.master], [], [], max(0, deadline-time.monotonic()))[0]:
                try:
                    result += os.read(self.master, 65536)
                except OSError:
                    break
        self.output += result
        return result

    def until(self, token, timeout=6):
        deadline = time.monotonic() + timeout
        while token not in self.output and time.monotonic() < deadline:
            self.read(.1)
        return token in self.output

    def send(self, keys):
        os.write(self.master, keys)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2)
        self.read(.05)
        os.close(self.master)
        os.close(self.slave)


class DatafetchTests(unittest.TestCase):
    def cli(self, *args, timeout=4, **env):
        try:
            return subprocess.run(['bash', str(SCRIPT), *args], capture_output=True,
                                  text=True, timeout=timeout,
                                  env={**os.environ, 'TERM': 'xterm-256color', **env})
        except subprocess.TimeoutExpired:
            self.fail('The command did not terminate as requested')

    def shell(self, body, *args):
        try:
            r = subprocess.run(['bash', '-c', 'source "$1"; shift; ' + body,
                                'test', str(SCRIPT), *map(str, args)],
                               capture_output=True, text=True, timeout=4)
        except subprocess.TimeoutExpired:
            self.fail('Sourcing the script must not start the dashboard')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, '')
        return r.stdout.strip()

    def test_help_exits_without_starting_dashboard(self):
        r = self.cli('--help')
        self.assertEqual(r.returncode, 0)
        self.assertIn('--once', r.stdout)
        self.assertNotIn('\x1b', r.stdout)
        self.assertEqual(r.stderr, '')

    def test_snapshot_and_pipe_are_plain_text(self):
        for args in [('--once',), ()]:
            with self.subTest(args=args):
                r = self.cli(*args)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stderr, '')
                self.assertNotIn('\x1b', r.stdout)
                self.assertIn('Klod Cripta', r.stdout.splitlines()[0])
                self.assertEqual(r.stdout.count('Klod Cripta'), 1)
                self.assertIn('RAM', r.stdout)
                self.assertIn('DISK', r.stdout)
                self.assertIn('NET', r.stdout)

    def test_invalid_options_fail_promptly(self):
        for args in [('--interval', '0'), ('--interval', 'nan'),
                     ('--interval', '-1'), ('--interval',), ('--unknown',)]:
            with self.subTest(args=args):
                r = self.cli(*args, timeout=1)
                self.assertEqual(r.returncode, 2)
                self.assertTrue(r.stderr.strip())
                self.assertNotIn('\x1b', r.stderr)

    def test_snapshot_ascii_and_width(self):
        r = self.cli('--once', '--ascii', '--width', '56')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.isascii())
        self.assertTrue(all(len(line) <= 56 for line in r.stdout.splitlines()))

    def test_icons_can_be_disabled_without_losing_unicode_frames(self):
        for args, enabled in [((), True), (('--no-icons',), False),
                              (('--ascii',), False)]:
            with self.subTest(args=args):
                r = self.cli('--once', '--width', '110', *args, LC_ALL='C.UTF-8')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(r.stderr, '')
                self.assertNotIn('\x1b', r.stdout)
                for icon_label in ('▣ CPU', '▧ GPU', '⇅ NET'):
                    self.assertEqual(icon_label in r.stdout, enabled)
                self.assertEqual('╭' in r.stdout, '--ascii' not in args)
                self.assertEqual(max(map(len, r.stdout.splitlines())), 110)
                self.assertIn('Snapshot / run without --once', r.stdout)

    def test_non_utf8_locale_uses_ascii_without_icons(self):
        r = self.cli('--once', '--width', '56', LC_ALL='C')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, '')
        self.assertTrue(r.stdout.isascii())
        self.assertIn('CPU', r.stdout)

    def test_snapshot_explicit_width_can_exceed_default(self):
        r = self.cli('--once', '--ascii', '--width', '120')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(max(map(len, r.stdout.splitlines())), 120)

    def test_small_columns_environment_does_not_break_snapshot(self):
        r = self.cli('--once', COLUMNS='10')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, '')
        self.assertIn('RAM', r.stdout)

    def test_memory_uses_available_and_swap_handles_disabled(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'meminfo'
            p.write_text('MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n')
            self.assertEqual(self.shell('read_memory "$1"; printf "%s %s %s %s" "$RAM_TOTAL" "$RAM_USED" "$RAM_PERCENT" "$SWAP_PERCENT"', p), '1024000 614400 60 0')

    def test_memory_display_keeps_units_when_used_and_total_differ(self):
        self.assertEqual(self.shell('memory_note 536870912 17179869184; printf "%s" "$REPLY"'), '512.0 MiB / 16.0 GiB')

    def test_desktop_names_preserve_identity_across_sessions(self):
        cases = [('KDE', 'KDE Plasma'), ('plasmawayland', 'KDE Plasma'),
                 ('plasma.desktop', 'KDE Plasma'), ('ubuntu:GNOME', 'GNOME'),
                 ('GNOME-Classic:GNOME', 'GNOME Classic'), ('X-Cinnamon', 'Cinnamon'),
                 ('LXQt', 'LXQt'), ('xfce', 'Xfce'), ('MATE', 'MATE'),
                 ('Budgie:GNOME', 'Budgie'), ('Hyprland', 'Hyprland'),
                 ('MyCustomDesktop', 'MyCustomDesktop'), ('', 'n/a')]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(self.shell('normalize_desktop_name "$1"; printf "%s" "$REPLY"', raw), expected)

    def package_scan(self, inventory, root):
        return self.shell('''
            INVENTORY=" $1 "
            command() {
                if [[ $1 == -v ]]; then [[ $INVENTORY == *" $2 "* ]]; return; fi
                builtin command "$@"
            }
            pacman() { printf 'pkg-a\\npkg-b\\n'; }
            dpkg-query() { printf 'installed\\nconfig-files\\ninstalled\\n'; }
            rpm() { printf 'pkg-a\\npkg-b\\n'; }
            flatpak() { printf 'org.example.App\\n'; }
            get_packages "$2"
            printf '%s|%s|%s|%s|%s' "$PKG_MANAGER" "$PKG_COUNT" "$PKG_MANAGERS" "$AUR_HELPERS" "$FLATPAK_COUNT"
        ''', inventory, root)

    def test_package_managers_and_aur_helpers_across_distributions(self):
        cases = [
            ('pacman paru pikaur', 'pacman|2|pacman|paru, pikaur|'),
            ('pacman', 'pacman|2|pacman|non pervenuto|'),
            ('apt dpkg-query flatpak snap', 'apt|2|apt, flatpak, snap|non pervenuto|1'),
            ('rpm dnf', 'dnf|2|dnf|non pervenuto|'),
            ('rpm zypper', 'zypper|2|zypper|non pervenuto|'),
            ('dpkg-query', 'dpkg|2|dpkg|non pervenuto|'),
            ('', 'n/a|n/a|n/a|non pervenuto|'),
        ]
        with tempfile.TemporaryDirectory() as root:
            for inventory, expected in cases:
                with self.subTest(inventory=inventory):
                    self.assertEqual(self.package_scan(inventory, root), expected)
            (Path(root)/'var/db/pkg/sys-apps/example-1').mkdir(parents=True)
            self.assertEqual(self.package_scan('emerge', root), 'Portage|1|Portage|non pervenuto|')

    def test_failed_package_query_is_unknown_not_zero(self):
        out = self.shell('''
            command() { [[ $1 == -v && $2 == pacman ]]; }
            pacman() { return 1; }
            get_packages; printf '%s' "$PKG_COUNT"
        ''')
        self.assertEqual(out, 'n/a')

    def test_shell_uses_launching_shell_then_configured_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for pid, name, parent in [('100', 'wrapper', '101'), ('101', 'zsh', '1')]:
                p = root/pid
                p.mkdir()
                (p/'comm').write_text(name+'\n')
                (p/'status').write_text(f'Name:\t{name}\nPPid:\t{parent}\n')
            self.assertEqual(self.shell('SHELL=/bin/bash; get_shell "$1" 100; printf "%s" "$SHELL_NAME"', root), 'zsh')
            self.assertEqual(self.shell('SHELL=/bin/fish; get_shell "$1" 999; printf "%s" "$SHELL_NAME"', root), 'fish')
            self.assertEqual(self.shell('unset SHELL; getent() { printf "/unexpected-nss-lookup"; }; '
                                        'get_shell "$1" 999; printf "%s" "$SHELL_NAME"', root), 'n/a')

    def test_audio_server_is_detected_from_running_processes(self):
        for process, expected in [('pipewire', 'PipeWire'), ('pulseaudio', 'PulseAudio'),
                                  ('jackd', 'JACK'), ('none', 'n/a')]:
            with self.subTest(process=process):
                self.assertEqual(self.shell('RUNNING=$1; pgrep() { [[ ${*: -1} == "$RUNNING" ]]; }; '
                                            'get_audio_server; printf "%s" "$AUDIO_SERVER"', process), expected)

    def test_small_details_view_keeps_footer_with_battery(self):
        out = self.shell('collect_static; sample; SMALL=1; DETAILS=1; WIDTH=45; ROWS=16; COLS=48; ACTIVE=1; BAT_NAME=BAT0; BAT_PERCENT=70; BAT_STATUS=Charging; build_frame; printf "%s\\n" "${FRAME[@]}"')
        self.assertLessEqual(len(out.splitlines()), 16)
        self.assertIn('q quit', out.splitlines()[-1])

    def test_software_fields_are_visible_in_roomy_overview(self):
        out = self.shell('collect_static; sample; COLS=120; ROWS=30; WIDTH=117; ACTIVE=1; '
                         'SMALL=0; DETAILS=0; PKG_MANAGERS="pacman, flatpak, snap"; '
                         'AUR_HELPERS="paru, pikaur"; SHELL_NAME=zsh; INIT_SYSTEM=systemd; '
                         'FILESYSTEM_NAME=ext4; AUDIO_SERVER=PipeWire; DE_NAME="KDE Plasma"; '
                         'build_frame; printf "%s\\n" "${FRAME[@]}"')
        for value in ('SOFTWARE', 'MANAGERS', 'pacman, flatpak, snap', 'AUR', 'paru, pikaur',
                      'SHELL', 'zsh', 'INIT', 'systemd', 'ROOT FS', 'ext4', 'AUDIO', 'PipeWire', 'KDE Plasma'):
            self.assertIn(value, out)

    def test_small_details_pages_expose_software_without_hiding_live_readings(self):
        out = self.shell('collect_static; sample; COLS=48; ROWS=16; WIDTH=45; ACTIVE=1; '
                         'SMALL=1; DETAILS=1; BAT_NAME=BAT0; BAT_PERCENT=70; BAT_STATUS=Charging; '
                         'PKG_MANAGERS="pacman, flatpak, snap"; AUR_HELPERS="paru, pikaur"; '
                         'SHELL_NAME=zsh; INIT_SYSTEM=systemd; FILESYSTEM_NAME=ext4; '
                         'AUDIO_SERVER=PipeWire; DE_NAME="KDE Plasma"; '
                         'for ((page=0; page<20 && DETAILS; page++)); do '
                         'build_frame; printf "%s\\n" "${FRAME[@]}"; printf "\\036"; handle_key d; done; true')
        pages = [p.strip() for p in out.split('\x1e') if p.strip()]
        self.assertGreater(len(pages), 1)
        for page in pages:
            lines = ANSI.sub('', page).splitlines()
            self.assertLessEqual(len(lines), 16)
            self.assertTrue(all(len(line) < 48 for line in lines))
            self.assertIn('q quit', lines[-1])
            for label in ('CPU', 'RAM', 'SWAP', 'DISK', 'NET', 'BAT'):
                self.assertIn(label, page)
        for value in ('MANAGERS', 'pacman, flatpak, snap', 'AUR', 'paru, pikaur',
                      'SHELL', 'zsh', 'INIT', 'systemd', 'ROOT FS', 'ext4', 'AUDIO', 'PipeWire', 'KDE Plasma'):
            self.assertIn(value, out)

    def test_gpu_names_prefer_marketing_label_and_keep_ambiguous_models(self):
        cases = [
            ('NVIDIA Corporation GA106 [GeForce RTX 3060 Lite Hash Rate] (rev a1)',
             'NVIDIA GeForce RTX 3060 LHR'),
            ('Intel Corporation Skylake GT2 [HD Graphics 520] (rev 07)',
             'Intel HD Graphics 520'),
            ('Advanced Micro Devices, Inc. [AMD/ATI] Navi 23 [Radeon RX 6600/6600 XT/6600M]',
             'AMD Radeon RX 6600/6600 XT/6600M'),
            ('Advanced Micro Devices, Inc. [AMD/ATI] Barcelo',
             'AMD Radeon (Barcelo)'),
        ]
        for raw, expected in cases:
            with self.subTest(raw=raw):
                self.assertEqual(self.shell('normalize_gpu_name "$1" "AMD Ryzen 5 7430U"; printf "%s" "$REPLY"', raw), expected)

    def test_gpu_codename_does_not_guess_an_unrelated_cpu_or_dedicated_gpu(self):
        self.assertEqual(self.shell('normalize_gpu_name "$1" "AMD Ryzen 7 5825U"; printf "%s" "$REPLY"',
                                   'Advanced Micro Devices, Inc. [AMD/ATI] Barcelo'),
                         'AMD Radeon (Barcelo)')
        self.assertEqual(self.shell('normalize_gpu_name "$1" "AMD Ryzen 5 7430U"; printf "%s" "$REPLY"',
                                   'NVIDIA Corporation TU117M [GeForce GTX 1650 Mobile]'),
                         'NVIDIA GeForce GTX 1650 Mobile')

    def gpu_device(self, root, slot, vendor, device, revision='00', boot='0'):
        path = root/'sys/bus/pci/devices'/slot
        path.mkdir(parents=True)
        for key, value in {'class': '0x030000', 'vendor': '0x'+vendor,
                           'device': '0x'+device, 'revision': '0x'+revision,
                           'boot_vga': boot}.items():
            (path/key).write_text(value+'\n')
        return path

    def gpu_scan(self, root, pci='', amd='', lspci=''):
        (root/'pci.ids').write_text(pci)
        (root/'amdgpu.ids').write_text(amd)
        (root/'lspci.txt').write_text(lspci)
        return self.shell('GPU_FIXTURE=$1; lspci() { cat "$GPU_FIXTURE/lspci.txt"; }; '
                          'get_gpus "$1/sys" "$1/pci.ids" "$1/amdgpu.ids" "$1/nvidia"; '
                          'printf "%s\\n" "${GPU_NAMES[@]}"', root).splitlines()

    def test_amd_gpu_uses_device_and_revision_without_lspci(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            device = self.gpu_device(root, '0000:04:00.0', '1002', '15d8', 'c2')
            pci = '1002  Advanced Micro Devices, Inc. [AMD/ATI]\n\t15d8  Picasso [Radeon Vega Series]\n'
            amd = '15D8, C1, AMD Radeon Vega 10 Graphics\n15D8, C2, AMD Radeon Vega 8 Graphics\n'
            self.assertEqual(self.gpu_scan(root, pci, amd), ['AMD Radeon Vega 8 (Picasso)'])
            (device/'revision').write_text('0xc1\n')
            self.assertEqual(self.gpu_scan(root, pci, amd), ['AMD Radeon Vega 10 (Picasso)'])

    def test_ambiguous_amd_revision_keeps_pci_family(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.gpu_device(root, '0000:04:00.0', '1002', '15d8', 'db')
            pci = '1002  Advanced Micro Devices, Inc. [AMD/ATI]\n\t15d8  Picasso [Radeon Vega Series]\n'
            amd = '15D8, DB, AMD Radeon Vega 3 Graphics\n15D8, DB, AMD Radeon Vega 8 Graphics\n'
            names = self.gpu_scan(root, pci, amd)
            self.assertIn('Radeon Vega Series', names[0])
            self.assertNotIn('Vega 3', names[0])
            self.assertNotIn('Vega 8', names[0])

    def test_generic_amd_database_label_keeps_informative_pci_family(self):
        cases = [
            ('67df', 'e3', 'Ellesmere', 'Radeon RX 470/480/570/570X/580/580X/590',
             'AMD Radeon RX Series'),
            ('687f', 'c1', 'Vega 10 XL/XT', 'Radeon RX Vega 56/64',
             'AMD Radeon RX Vega'),
        ]
        for device, revision, chip, family, generic in cases:
            with self.subTest(device=device), tempfile.TemporaryDirectory() as d:
                root = Path(d)
                self.gpu_device(root, '0000:04:00.0', '1002', device, revision)
                pci = ('1002  Advanced Micro Devices, Inc. [AMD/ATI]\n'
                       f'\t{device}  {chip} [{family}]\n')
                amd = f'{device}, {revision}, {generic}\n'
                self.assertEqual(self.gpu_scan(root, pci, amd), [f'AMD {family}'])

    def test_intel_nvidia_and_duplicate_drm_nodes(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            nvidia = self.gpu_device(root, '0000:01:00.0', '10de', '2504')
            intel = self.gpu_device(root, '0000:02:00.0', '8086', '1916', boot='1')
            for i, path in enumerate((nvidia, intel)):
                card = root/f'sys/class/drm/card{i}'
                card.mkdir(parents=True)
                (card/'device').symlink_to(path)
            pci = ('10de  NVIDIA Corporation\n\t2504  GA106 [GeForce RTX 3060 Lite Hash Rate]\n'
                   '8086  Intel Corporation\n\t1916  Skylake GT2 [HD Graphics 520]\n')
            self.assertEqual(self.gpu_scan(root, pci),
                             ['Intel HD Graphics 520', 'NVIDIA GeForce RTX 3060 LHR'])

    def test_gpu_machine_readable_lspci_without_sysfs(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            pci = ('Slot:\t0000:04:00.0\nClass:\tVGA compatible controller [0300]\n'
                   'Vendor:\tAdvanced Micro Devices, Inc. [AMD/ATI] [1002]\n'
                   'Device:\tBarcelo [15e7]\nRev:\tc1\n')
            self.assertEqual(self.gpu_scan(root, lspci=pci), ['AMD Radeon (Barcelo)'])

    def test_unknown_gpu_keeps_numeric_identity(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.gpu_device(root, '0000:05:00.0', '1002', 'abcd')
            self.assertEqual(self.gpu_scan(root), ['AMD GPU [1002:abcd]'])
            pci = ('Slot:\t0000:05:00.0\nClass:\tDisplay controller [0380]\n'
                   'Vendor:\tAdvanced Micro Devices, Inc. [AMD/ATI] [1002]\n'
                   'Device:\tDevice [abcd]\nRev:\t00\n')
            self.assertEqual(self.gpu_scan(root, lspci=pci), ['AMD GPU [1002:abcd]'])

    def test_nvidia_driver_model_matches_its_pci_slot(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            self.gpu_device(root, '0000:01:00.0', '10de', '2504')
            info = root/'nvidia/0000:01:00.0'
            info.mkdir(parents=True)
            (info/'information').write_text('Model: NVIDIA GeForce RTX 3060\nIRQ: 18\n')
            self.assertEqual(self.gpu_scan(root), ['NVIDIA GeForce RTX 3060'])

    def test_framed_views_fit_terminal_with_battery_and_details(self):
        for cols, rows in [(48, 16), (48, 18), (56, 20), (80, 23), (80, 24), (104, 20), (104, 24), (110, 24), (160, 40)]:
            for details in (0, 1):
                with self.subTest(cols=cols, rows=rows, details=details):
                    out = self.shell('collect_static; sample; COLS=$1; ROWS=$2; DETAILS=$3; '
                                     'WIDTH=$((COLS-3)); SMALL=0; ((WIDTH<69 || ROWS<23)) && SMALL=1; '
                                     'ACTIVE=1; GPU_NAMES=(); GPU_NAME=n/a; BAT_NAME=BAT0; BAT_PERCENT=70; BAT_STATUS=Charging; '
                                     'BAT_POWER=12.3; BAT_HEALTH=94; COLOR_MODE=always; setup_style; '
                                     'build_frame; printf "%s\\n" "${FRAME[@]}"', cols, rows, details)
                    lines = ANSI.sub('', out).splitlines()
                    self.assertLessEqual(len(lines), rows)
                    self.assertTrue(all(len(line) < cols for line in lines))
                    self.assertIn('q quit', lines[-1])
                    for label in ('CPU', 'RAM', 'SWAP', 'DISK', 'NET', 'BAT'):
                        self.assertIn(label, '\n'.join(lines))
                    if not details or (cols >= 104 and rows >= 24):
                        self.assertIn('GPU', '\n'.join(lines))
                    self.assertTrue(any('LIVE METRICS' in line and ('╭' in line or '+' in line) for line in lines))
                    if cols >= 104:
                        self.assertTrue(any('SYSTEM' in line and 'LIVE METRICS' in line for line in lines))
                        for group in ('MEMORY / STORAGE', 'NETWORK', 'POWER'):
                            self.assertTrue(any(('├' in line or '+' in line) and group in line for line in lines))

    def test_title_is_framed_and_cpu_chart_explains_its_samples(self):
        r = self.cli('--once', '--ascii', '--width', '110')
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertTrue(lines[0].strip().startswith('+'))
        self.assertTrue(lines[0].strip().endswith('+'))
        self.assertIn('Klod Cripta', lines[0])
        self.assertIn('D A T A F E T C H', r.stdout)
        out = self.shell('CW=32; CPU_HISTORY=(0 25 50 75 100); CELLS=(); history_section; '
                         'printf "%s\\n" "${CELLS[@]}"')
        self.assertIn('CPU USAGE / last 5 samples', out)
        self.assertIn('0-100%', out)

    def test_unicode_padding_uses_character_width_for_temperature(self):
        self.assertEqual(self.shell('fit 12 "51.4°C"; printf "[%s]" "$REPLY"'), '[51.4°C      ]')

    def test_cpu_deltas_exclude_guest_double_counting(self):
        with tempfile.TemporaryDirectory() as d:
            a, b = Path(d)/'a', Path(d)/'b'
            a.write_text('cpu 100 0 50 850 0 0 0 0 80 0\n')
            b.write_text('cpu 160 0 70 870 0 0 0 0 100 0\n')
            self.assertEqual(self.shell('read_cpu "$1"; read_cpu "$2"; printf "%s" "$CPU_PERCENT"', a, b), '80.0')

    def test_temperature_ignores_nvme_when_cpu_sensor_exists(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            for name, driver, value in [('hwmon0','nvme','81000'), ('hwmon1','k10temp','56500')]:
                h = root/name
                h.mkdir()
                (h/'name').write_text(driver+'\n')
                (h/'temp1_input').write_text(value+'\n')
                (h/'temp1_label').write_text('Composite\n' if driver=='nvme' else 'Tctl\n')
            self.assertEqual(self.shell('detect_temperature "$1" "$1/absent"; read_temperature; printf "%s" "$CPU_TEMP"', root), '56.5')

    def test_nvme_only_is_not_reported_as_cpu_temperature(self):
        with tempfile.TemporaryDirectory() as d:
            h = Path(d)/'hwmon0'
            h.mkdir()
            (h/'name').write_text('nvme\n')
            (h/'temp1_input').write_text('45000\n')
            self.assertEqual(self.shell('detect_temperature "$1" "$1/absent"; read_temperature; printf "%s" "$CPU_TEMP"', d), '')

    def test_temperature_prefers_physical_tdie_to_offset_tctl(self):
        with tempfile.TemporaryDirectory() as d:
            h = Path(d)/'hwmon0'
            h.mkdir()
            for name, value in {'name':'k10temp', 'temp1_label':'Tctl', 'temp1_input':'85000',
                                'temp2_label':'Tdie', 'temp2_input':'65000'}.items():
                (h/name).write_text(value+'\n')
            self.assertEqual(self.shell('detect_temperature "$1" "$1/absent"; read_temperature; printf "%s" "$CPU_TEMP"', d), '65.0')

    def test_battery_health_never_mixes_energy_and_charge_units(self):
        with tempfile.TemporaryDirectory() as d:
            b = Path(d)/'BAT1'
            b.mkdir()
            for name,value in {'type':'Battery','capacity':'40','status':'Discharging',
                               'energy_full':'49000000','charge_full':'4000000',
                               'charge_full_design':'5000000'}.items():
                (b/name).write_text(value+'\n')
            self.assertEqual(self.shell('read_battery "$1"; printf "%s" "$BAT_HEALTH"', d), '80')

    def test_discharging_battery_accepts_signed_current(self):
        with tempfile.TemporaryDirectory() as d:
            b = Path(d)/'BAT0'
            b.mkdir()
            for name,value in {'type':'Battery','capacity':'70','status':'Discharging',
                               'current_now':'-1500000','voltage_now':'12000000'}.items():
                (b/name).write_text(value+'\n')
            self.assertEqual(self.shell('read_battery "$1"; printf "%s" "$BAT_POWER"', d), '18.0')

    def test_suspend_restores_screen_and_foreground_resumes(self):
        pid, master = pty.fork()
        if pid == 0:
            os.environ['TERM'] = 'xterm-256color'
            os.environ['PS1'] = 'DF_TEST_PROMPT> '
            os.execvp('bash', ['bash', '--noprofile', '--norc', '-i'])
        data = b''
        def read_until(token, timeout=4):
            nonlocal data
            result = b''
            deadline = time.monotonic()+timeout
            while token not in result and time.monotonic()<deadline:
                if select.select([master], [], [], .1)[0]:
                    result += os.read(master, 65536)
            data += result
            self.assertIn(token, result)
            return result
        try:
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
            read_until(b'DF_TEST_PROMPT> ')
            os.write(master, ('bash '+str(SCRIPT)+'\n').encode())
            read_until(b'RAM')
            os.write(master, b'\x1a')
            stopped = read_until(b'DF_TEST_PROMPT> ')
            self.assertIn(b'\x1b[?25h', stopped)
            self.assertIn(b'\x1b[?1049l', stopped)
            os.write(master, b'fg\n')
            resumed = read_until(b'RAM')
            self.assertIn(b'\x1b[?1049h', resumed)
            os.write(master, b'q')
            read_until(b'DF_TEST_PROMPT> ')
        finally:
            # Shut down the job and its interactive parent, even after a failure.
            try:
                os.write(master, b'fg\nq\nexit\nexit\n')
                time.sleep(.1)
                os.kill(pid, signal.SIGHUP)
            except (OSError, ProcessLookupError):
                pass
            os.close(master)
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass

    def test_network_rates_use_elapsed_time_and_reset_on_interface_change(self):
        self.assertEqual(self.shell('network_sample 100 1000 2000 eth0; network_sample 300 3048 6096 eth0; printf "%s %s;" "$RX_RATE" "$TX_RATE"; network_sample 400 99 100 wlan0; printf "%s %s" "$RX_RATE" "$TX_RATE"'), '1024 2048;0 0')

    def test_network_counter_reset_never_reports_negative_speed(self):
        self.assertEqual(self.shell('network_sample 100 5000 6000 eth0; network_sample 200 10 20 eth0; printf "%s %s" "$RX_RATE" "$TX_RATE"'), '0 0')

    def test_battery_capacity_state_health_and_power(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'BAT0'
            p.mkdir()
            for name, value in {'type':'Battery','capacity':'73','status':'Charging',
                                'charge_full':'4500000','charge_full_design':'5000000',
                                'power_now':'15300000','present':'1'}.items():
                (p/name).write_text(value+'\n')
            self.assertEqual(self.shell('read_battery "$1"; printf "%s|%s|%s|%s" "$BAT_PERCENT" "$BAT_STATUS" "$BAT_HEALTH" "$BAT_POWER"', d), '73|Charging|90|15.3')

    def test_live_terminal_fits_80x24_and_restores_terminal(self):
        t = Terminal()
        try:
            self.assertTrue(t.until(b'RAM'), t.output[-300:])
            self.assertNotIn(b'Window too small', t.output)
            self.assertIn(b'\x1b[?1049h', t.output)
            t.send(b'q')
            t.process.wait(timeout=2)
            t.read(.1)
            self.assertEqual(t.process.returncode, 0)
            self.assertIn(b'\x1b[?25h', t.output)
            self.assertIn(b'\x1b[?1049l', t.output)
            self.assertEqual(termios.tcgetattr(t.slave), t.before)
        finally:
            t.close()

    def test_live_refresh_does_not_erase_the_screen(self):
        t = Terminal(cols=100, rows=42, args=('--interval','0.5'))
        try:
            self.assertTrue(t.until(b'RAM'), t.output[-300:])
            t.read(.1)
            update = t.read(1.2)
            self.assertNotRegex(update, rb'\x1b\[(?:0|2|3)?J')
            self.assertNotIn(b'Klod Cripta', update)
            self.assertTrue(update)
        finally:
            t.close()

    def test_pause_resume_and_resize_preserve_dashboard(self):
        t = Terminal(args=('--interval','0.5'))
        try:
            self.assertTrue(t.until(b'RAM'))
            t.send(b'p')
            self.assertTrue(t.until(b'PAUSED', timeout=2))
            t.read(.15)
            self.assertEqual(t.read(.65), b'')
            t.resize(56, 20)
            self.assertIn(b'RAM', t.read(.4))
            t.resize(100, 35)
            self.assertIn(b'CPU', t.read(.4))
            t.send(b'p')
            self.assertIn(b'LIVE', t.read(.4))
            t.send(b'd')
            self.assertIn(b'PACKAGES', t.read(.4))
        finally:
            t.close()

    def test_signal_exit_restores_terminal(self):
        t = Terminal()
        try:
            self.assertTrue(t.until(b'RAM'))
            os.kill(t.process.pid, signal.SIGINT)
            t.process.wait(timeout=2)
            t.read(.1)
            self.assertEqual(t.process.returncode, 130)
            self.assertEqual(termios.tcgetattr(t.slave), t.before)
            self.assertIn(b'\x1b[?25h', t.output)
            self.assertIn(b'\x1b[?1049l', t.output)
        finally:
            t.close()

    def test_fast_and_slow_keys_update_interval(self):
        t = Terminal()
        try:
            self.assertTrue(t.until(b'RAM'))
            t.send(b'+')
            self.assertIn(b'0.5s', t.read(.3))
            t.send(b'-')
            self.assertIn(b'1s', t.read(.3))
            t.send(b'\x04')
            t.process.wait(timeout=2)
            self.assertEqual(t.process.returncode, 0)
        finally:
            t.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
