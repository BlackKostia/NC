"""Reusable zero-dependency Linux /proc and statvfs telemetry collector."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Dict, List, Tuple


_SKIP_FS_TYPES = frozenset(
    {
        "autofs",
        "binfmt_misc",
        "bpf",
        "cgroup",
        "cgroup2",
        "configfs",
        "debugfs",
        "devpts",
        "devtmpfs",
        "efivarfs",
        "fuse.gvfsd-fuse",
        "fuse.portal",
        "fusectl",
        "hugetlbfs",
        "mqueue",
        "nsfs",
        "overlay",
        "proc",
        "pstore",
        "ramfs",
        "rpc_pipefs",
        "securityfs",
        "selinuxfs",
        "squashfs",
        "sysfs",
        "tmpfs",
        "tracefs",
    }
)


@dataclass
class MemoryStats:
    ram_total: int
    ram_used: int
    ram_available: int
    cached: int
    ram_pct: float
    swap_total: int
    swap_used: int
    swap_pct: float


@dataclass
class DiskStats:
    device: str
    mountpoint: str
    fstype: str
    total: int
    used: int
    free: int
    pct: float


@dataclass
class SystemInfo:
    hostname: str
    kernel: str
    cpu_model: str
    cores: int
    uptime_sec: float
    load_1m: float
    load_5m: float
    load_15m: float
    procs_running: int
    procs_total: int


@dataclass
class ProcessInfo:
    pid: int
    name: str
    state: str
    cpu_pct: float
    rss_bytes: int
    mem_pct: float


def _read_cpu_model_and_cores() -> Tuple[str, int]:
    model = "x86_64 CPU"
    cores = 0
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("model name") and model == "x86_64 CPU":
                    _, _, val = line.partition(":")
                    model = val.strip()
                elif line.startswith("processor"):
                    cores += 1
    except OSError:
        pass
    return model, max(1, cores)


def _parse_proc_stat() -> Dict[str, Tuple[int, int]]:
    """Return map of cpu_name -> (idle_ticks, total_ticks)."""
    result: Dict[str, Tuple[int, int]] = {}
    try:
        with open("/proc/stat", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if not line.startswith("cpu"):
                    break
                parts = line.split()
                name = parts[0]
                nums = [int(x) for x in parts[1:11]]
                while len(nums) < 8:
                    nums.append(0)
                idle = nums[3] + nums[4]  # idle + iowait
                total = sum(nums)
                result[name] = (idle, total)
    except OSError:
        pass
    return result


class CpuSampler:
    """Stateful CPU utilization sampler with rolling history."""

    def __init__(self, history_len: int = 120) -> None:
        self.history_len = history_len
        self.history: List[float] = []
        self._prev = _parse_proc_stat()
        self.total_pct: float = 0.0
        self.per_core: List[float] = []

    def sample(self) -> Tuple[float, List[float]]:
        curr = _parse_proc_stat()
        total_pct = 0.0
        cores: List[Tuple[int, float]] = []

        for name, (idle_now, total_now) in curr.items():
            prev_idle, prev_total = self._prev.get(name, (idle_now, total_now))
            d_total = total_now - prev_total
            d_idle = idle_now - prev_idle
            pct = 0.0 if d_total <= 0 else max(0.0, min(100.0, 100.0 * (1.0 - d_idle / d_total)))
            if name == "cpu":
                total_pct = pct
            elif name.startswith("cpu") and name[3:].isdigit():
                cores.append((int(name[3:]), pct))

        self._prev = curr
        cores.sort(key=lambda item: item[0])
        self.total_pct = total_pct
        self.per_core = [pct for _, pct in cores]
        self.history.append(total_pct)
        if len(self.history) > self.history_len:
            del self.history[: len(self.history) - self.history_len]
        return self.total_pct, self.per_core


def read_memory() -> MemoryStats:
    vals: Dict[str, int] = {}
    try:
        with open("/proc/meminfo", "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                key, _, rest = line.partition(":")
                num_str = rest.strip().split(" ", 1)[0]
                if num_str.isdigit():
                    vals[key] = int(num_str) * 1024
    except OSError:
        pass

    total = vals.get("MemTotal", 0)
    avail = vals.get("MemAvailable", vals.get("MemFree", 0))
    cached = vals.get("Cached", 0) + vals.get("Buffers", 0)
    used = max(0, total - avail)
    ram_pct = (100.0 * used / total) if total > 0 else 0.0

    swap_total = vals.get("SwapTotal", 0)
    swap_free = vals.get("SwapFree", 0)
    swap_used = max(0, swap_total - swap_free)
    swap_pct = (100.0 * swap_used / swap_total) if swap_total > 0 else 0.0

    return MemoryStats(
        ram_total=total,
        ram_used=used,
        ram_available=avail,
        cached=cached,
        ram_pct=ram_pct,
        swap_total=swap_total,
        swap_used=swap_used,
        swap_pct=swap_pct,
    )


def read_system_info() -> SystemInfo:
    uname = os.uname()
    cpu_model, cores = _read_cpu_model_and_cores()
    uptime_sec = 0.0
    load_1m = load_5m = load_15m = 0.0
    procs_running = procs_total = 0

    try:
        with open("/proc/uptime", "r", encoding="utf-8", errors="ignore") as f:
            uptime_sec = float(f.read().split()[0])
    except (OSError, ValueError, IndexError):
        pass

    try:
        with open("/proc/loadavg", "r", encoding="utf-8", errors="ignore") as f:
            parts = f.read().split()
            load_1m, load_5m, load_15m = float(parts[0]), float(parts[1]), float(parts[2])
            if "/" in parts[3]:
                r_str, t_str = parts[3].split("/", 1)
                procs_running, procs_total = int(r_str), int(t_str)
    except (OSError, ValueError, IndexError):
        pass

    return SystemInfo(
        hostname=uname.nodename,
        kernel=uname.release,
        cpu_model=cpu_model,
        cores=cores,
        uptime_sec=uptime_sec,
        load_1m=load_1m,
        load_5m=load_5m,
        load_15m=load_15m,
        procs_running=procs_running,
        procs_total=procs_total,
    )


def read_disks() -> List[DiskStats]:
    disks: List[DiskStats] = []
    seen_devs: set[int] = set()
    try:
        with open("/proc/mounts", "r", encoding="utf-8", errors="ignore") as f:
            lines = f.readlines()
    except OSError:
        return disks

    for line in lines:
        parts = line.split()
        if len(parts) < 3:
            continue
        dev, mount, fstype = parts[0], parts[1], parts[2]
        if fstype in _SKIP_FS_TYPES or mount.startswith(("/proc", "/sys", "/dev", "/run")):
            continue
        mount = mount.replace("\\040", " ")
        try:
            st = os.stat(mount)
            if st.st_dev in seen_devs:
                continue
            seen_devs.add(st.st_dev)
            vfs = os.statvfs(mount)
        except OSError:
            continue
        total = vfs.f_blocks * vfs.f_frsize
        if total <= 0:
            continue
        free = vfs.f_bavail * vfs.f_frsize
        used = max(0, total - vfs.f_bfree * vfs.f_frsize)
        pct = 100.0 * used / total
        disks.append(
            DiskStats(
                device=dev,
                mountpoint=mount,
                fstype=fstype,
                total=total,
                used=used,
                free=free,
                pct=pct,
            )
        )
    disks.sort(key=lambda d: (0 if d.mountpoint == "/" else 1, d.mountpoint))
    return disks


class ProcessSampler:
    """Samples top processes with per-process CPU% delta."""

    def __init__(self) -> None:
        self._page_size = os.sysconf("SC_PAGESIZE")
        self._prev_proc_ticks: Dict[int, int] = {}
        self._prev_total_ticks: int = 0

    @staticmethod
    def _total_cpu_ticks() -> int:
        stat = _parse_proc_stat()
        _, total = stat.get("cpu", (0, 0))
        return total

    def sample(
        self,
        mem_total: int,
        limit: int = 10,
        sort_by: str = "mem",
    ) -> List[ProcessInfo]:
        total_now = self._total_cpu_ticks()
        d_total = max(1, total_now - self._prev_total_ticks)
        new_ticks: Dict[int, int] = {}
        procs: List[ProcessInfo] = []

        try:
            entries = os.listdir("/proc")
        except OSError:
            return procs

        for entry in entries:
            if not entry.isdigit():
                continue
            pid = int(entry)
            stat_path = f"/proc/{pid}/stat"
            try:
                with open(stat_path, "r", encoding="utf-8", errors="ignore") as f:
                    raw = f.read()
            except OSError:
                continue

            lpar = raw.find("(")
            rpar = raw.rfind(")")
            if lpar < 0 or rpar <= lpar:
                continue
            name = raw[lpar + 1 : rpar]
            rest = raw[rpar + 2 :].split()
            if len(rest) < 22:
                continue
            state = rest[0]
            utime = int(rest[11])
            stime = int(rest[12])
            rss_pages = int(rest[21])

            proc_ticks = utime + stime
            new_ticks[pid] = proc_ticks
            prev_ticks = self._prev_proc_ticks.get(pid)
            if prev_ticks is None or self._prev_total_ticks == 0:
                cpu_pct = 0.0
            else:
                cpu_pct = max(0.0, 100.0 * (proc_ticks - prev_ticks) / d_total)

            rss_bytes = max(0, rss_pages * self._page_size)
            mem_pct = (100.0 * rss_bytes / mem_total) if mem_total > 0 else 0.0
            procs.append(
                ProcessInfo(
                    pid=pid,
                    name=name,
                    state=state,
                    cpu_pct=cpu_pct,
                    rss_bytes=rss_bytes,
                    mem_pct=mem_pct,
                )
            )

        self._prev_proc_ticks = new_ticks
        self._prev_total_ticks = total_now

        if sort_by == "cpu":
            procs.sort(key=lambda p: (-p.cpu_pct, -p.rss_bytes, p.pid))
        elif sort_by == "pid":
            procs.sort(key=lambda p: p.pid)
        else:
            procs.sort(key=lambda p: (-p.rss_bytes, -p.cpu_pct, p.pid))
        return procs[:limit]
