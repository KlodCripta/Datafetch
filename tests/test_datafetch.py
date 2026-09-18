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
                self.assertIn('DATAFETCH', r.stdout)
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

    def test_small_details_view_keeps_footer_with_battery(self):
        out = self.shell('collect_static; sample; SMALL=1; DETAILS=1; WIDTH=45; ROWS=16; COLS=48; ACTIVE=1; BAT_NAME=BAT0; BAT_PERCENT=70; BAT_STATUS=Charging; build_frame; printf "%s\\n" "${FRAME[@]}"')
        self.assertLessEqual(len(out.splitlines()), 16)
        self.assertIn('q quit', out.splitlines()[-1])

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
            self.assertNotIn(b'DATAFETCH', update)
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
