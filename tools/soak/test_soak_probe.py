"""tools/soak/soak_probe.py: Blender RSS and open handles on macOS and Linux (task 2.7; NFR-REL-003)."""

import os
import platform
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import soak_probe as sp  # noqa: E402

LSOF = "p4242\nfcwd\nftxt\nftxt\nf0\nf1\nf2\nf17\nfNOFD\nfmem\n"


def test_parse_ps_rss() -> None:
    assert sp.parse_ps_rss_kib("  812345\n") == 812345
    assert sp.parse_ps_rss_kib("") is None
    assert sp.parse_ps_rss_kib("RSS\n") is None


def test_parse_lsof_counts_only_numbered_descriptors() -> None:
    assert sp.parse_lsof_fds(LSOF) == 4
    assert sp.parse_lsof_fds("") == 0


def test_parse_proc_status() -> None:
    status = "Name:\tblender\nVmPeak:\t 900000 kB\nVmRSS:\t  654321 kB\nThreads:\t40\n"
    assert sp.parse_proc_status_rss_kib(status) == 654321
    assert sp.parse_proc_status_rss_kib("Name:\tzombie\n") is None


def test_macos_sample_uses_ps_and_lsof() -> None:
    calls: list[list[str]] = []

    def fake_run(cmd: list[str]) -> str | None:
        calls.append(cmd)
        return " 1024\n" if cmd[0] == "ps" else LSOF

    assert sp.sample_process(4242, system="Darwin", run=fake_run) == (1024, 4)
    assert calls == [["ps", "-o", "rss=", "-p", "4242"], ["lsof", "-n", "-P", "-F", "f", "-p", "4242"]]


def test_macos_sample_of_a_gone_process_is_empty() -> None:
    assert sp.sample_process(4242, system="Darwin", run=lambda cmd: None) == (None, None)


def test_linux_sample_reads_proc(tmp_path: Path) -> None:
    proc = tmp_path / "4242"
    (proc / "fd").mkdir(parents=True)
    (proc / "status").write_text("Name:\tblender\nVmRSS:\t 2048 kB\n", encoding="utf-8")
    for fd in ("0", "1", "2", "9"):
        (proc / "fd" / fd).touch()
    assert sp.sample_process(4242, system="Linux", proc_root=tmp_path) == (2048, 4)
    assert sp.sample_process(4343, system="Linux", proc_root=tmp_path) == (None, None)


def test_unsupported_platform() -> None:
    with pytest.raises(sp.UnsupportedPlatformError):
        sp.sample_process(1, system="Windows")


def test_pid_alive() -> None:
    assert sp.pid_alive(os.getpid()) is True
    assert sp.pid_alive(None) is False
    assert sp.pid_alive(0) is False


@pytest.mark.skipif(platform.system() not in ("Darwin", "Linux"), reason="macOS and Linux only")
def test_samples_this_process() -> None:
    rss, handles = sp.sample_process(os.getpid())
    assert rss is not None and rss > 1000
    assert handles is not None and handles >= 3
