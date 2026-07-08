#!/usr/bin/env python3
"""Managed local TCP relay for GOST SNI Manager.

GOST dispatches each SNI to a local 127.0.0.1 relay port. This relay connects
to the real target and enforces bandwidth/traffic/expiry limits stored in SQLite.
"""
from __future__ import annotations

import asyncio
import logging
import os
import signal
import socket
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Optional, Tuple

DATA_DIR = Path(os.environ.get("GOST_PANEL_DATA", "/etc/gost-panel"))
DB_FILE = Path(os.environ.get("GOST_PANEL_DB", str(DATA_DIR / "gsm.db")))
RELAY_HOST = os.environ.get("GSM_RELAY_HOST", "127.0.0.1")
REFRESH_INTERVAL = float(os.environ.get("GSM_RELAY_REFRESH", "5"))
FLUSH_INTERVAL = float(os.environ.get("GSM_RELAY_FLUSH", "2"))
BUFFER_SIZE = int(os.environ.get("GSM_RELAY_BUFFER", "65536"))

logging.basicConfig(level=os.environ.get("GSM_RELAY_LOG", "INFO"), format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("gsm-relay")


@dataclass
class Rule:
    id: str
    owner_id: str
    sni: str
    target: str
    port: int
    relay_port: int
    speed_limit_mbps: Optional[float]
    traffic_limit_gb: Optional[float]
    owner_enabled: int
    owner_expires_at: Optional[str]
    account_traffic_limit_gb: Optional[float]
    enabled: int
    bytes_up: int
    bytes_down: int


class RateLimiter:
    def __init__(self, mbps: Optional[float]):
        self.rate = 0.0 if not mbps or mbps <= 0 else float(mbps) * 1024 * 1024 / 8
        self.capacity = max(self.rate, BUFFER_SIZE * 2)
        self.tokens = self.capacity
        self.updated = time.monotonic()
        self.lock = asyncio.Lock()

    async def wait(self, amount: int) -> None:
        if self.rate <= 0:
            return
        async with self.lock:
            while True:
                now = time.monotonic()
                elapsed = now - self.updated
                self.updated = now
                self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
                if self.tokens >= amount:
                    self.tokens -= amount
                    return
                need = (amount - self.tokens) / self.rate
                await asyncio.sleep(min(max(need, 0.001), 1.0))


class RelayManager:
    def __init__(self):
        self.servers: Dict[str, asyncio.AbstractServer] = {}
        self.limiters: Dict[str, RateLimiter] = {}
        self.rules: Dict[str, Rule] = {}
        self.pending: Dict[str, Tuple[int, int]] = {}
        self.pending_lock = asyncio.Lock()
        self.stopping = asyncio.Event()

    def db(self) -> sqlite3.Connection:
        conn = sqlite3.connect(DB_FILE)
        conn.row_factory = sqlite3.Row
        return conn

    def parse_dt(self, value: Optional[str]) -> Optional[datetime]:
        if not value:
            return None
        try:
            if value.endswith("Z"):
                value = value[:-1] + "+00:00"
            dt = datetime.fromisoformat(value)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc)
        except Exception:
            return None

    def gb_to_bytes(self, value) -> Optional[int]:
        if value is None or value == "":
            return None
        try:
            v = float(value)
        except Exception:
            return None
        if v <= 0:
            return None
        return int(v * 1024 * 1024 * 1024)

    def row_to_rule(self, row: sqlite3.Row) -> Rule:
        return Rule(
            id=row["id"], owner_id=row["owner_id"], sni=row["sni"], target=row["target"], port=int(row["port"]),
            relay_port=int(row["relay_port"]), speed_limit_mbps=row["speed_limit_mbps"], traffic_limit_gb=row["traffic_limit_gb"],
            owner_enabled=int(row["owner_enabled"]), owner_expires_at=row["owner_expires_at"],
            account_traffic_limit_gb=row["account_traffic_limit_gb"], enabled=int(row["enabled"]),
            bytes_up=int(row["bytes_up"] or 0), bytes_down=int(row["bytes_down"] or 0),
        )

    def load_rules(self) -> Dict[str, Rule]:
        if not DB_FILE.exists():
            return {}
        with self.db() as db:
            rows = db.execute(
                """SELECT r.*, u.enabled owner_enabled, u.expires_at owner_expires_at,
                u.account_traffic_limit_gb FROM rules r JOIN users u ON u.id=r.owner_id WHERE r.enabled=1"""
            ).fetchall()
        rules = {}
        for row in rows:
            rule = self.row_to_rule(row)
            if self.rule_active_sync(rule):
                rules[rule.id] = rule
        return rules

    def owner_used_bytes(self, owner_id: str) -> int:
        with self.db() as db:
            row = db.execute("SELECT COALESCE(SUM(bytes_up + bytes_down),0) used FROM rules WHERE owner_id=?", (owner_id,)).fetchone()
        used = int(row["used"] or 0)
        # Add pending bytes for all rules owned by this account.
        for rid, (up, down) in self.pending.items():
            r = self.rules.get(rid)
            if r and r.owner_id == owner_id:
                used += up + down
        return used

    def rule_used_bytes(self, rule_id: str, rule: Optional[Rule] = None) -> int:
        if rule is None:
            rule = self.rules.get(rule_id)
        if not rule:
            return 0
        used = int(rule.bytes_up) + int(rule.bytes_down)
        up, down = self.pending.get(rule_id, (0, 0))
        return used + up + down

    def rule_active_sync(self, rule: Rule) -> bool:
        if rule.enabled != 1 or rule.owner_enabled != 1:
            return False
        exp = self.parse_dt(rule.owner_expires_at)
        if exp and exp <= datetime.now(timezone.utc):
            return False
        rule_limit = self.gb_to_bytes(rule.traffic_limit_gb)
        if rule_limit is not None and int(rule.bytes_up + rule.bytes_down) >= rule_limit:
            return False
        acc_limit = self.gb_to_bytes(rule.account_traffic_limit_gb)
        if acc_limit is not None:
            try:
                if self.owner_used_bytes(rule.owner_id) >= acc_limit:
                    return False
            except Exception:
                pass
        return True

    async def rule_active(self, rule: Rule) -> bool:
        if rule.enabled != 1 or rule.owner_enabled != 1:
            return False
        exp = self.parse_dt(rule.owner_expires_at)
        if exp and exp <= datetime.now(timezone.utc):
            return False
        rule_limit = self.gb_to_bytes(rule.traffic_limit_gb)
        if rule_limit is not None and self.rule_used_bytes(rule.id, rule) >= rule_limit:
            return False
        acc_limit = self.gb_to_bytes(rule.account_traffic_limit_gb)
        if acc_limit is not None and self.owner_used_bytes(rule.owner_id) >= acc_limit:
            return False
        return True

    async def add_pending(self, rule_id: str, direction: str, amount: int) -> None:
        async with self.pending_lock:
            up, down = self.pending.get(rule_id, (0, 0))
            if direction == "up":
                up += amount
            else:
                down += amount
            self.pending[rule_id] = (up, down)

    async def flush_stats(self) -> None:
        async with self.pending_lock:
            items = list(self.pending.items())
            self.pending.clear()
        if not items:
            return
        with self.db() as db:
            for rid, (up, down) in items:
                db.execute("UPDATE rules SET bytes_up=bytes_up+?, bytes_down=bytes_down+?, updated_at=? WHERE id=?", (up, down, datetime.now(timezone.utc).replace(microsecond=0).isoformat(), rid))
            db.commit()
        # Refresh local counters.
        for rid, (up, down) in items:
            if rid in self.rules:
                self.rules[rid].bytes_up += up
                self.rules[rid].bytes_down += down

    async def serve_rule(self, rule: Rule) -> None:
        async def handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            peer = writer.get_extra_info("peername")
            if not await self.rule_active(rule):
                log.info("reject rule=%s sni=%s peer=%s reason=inactive_or_quota", rule.id, rule.sni, peer)
                writer.close()
                await writer.wait_closed()
                return
            try:
                target_reader, target_writer = await asyncio.open_connection(rule.target, rule.port, family=socket.AF_UNSPEC)
                log.info("connect rule=%s sni=%s peer=%s target=%s:%s", rule.id, rule.sni, peer, rule.target, rule.port)
                limiter = self.limiters.setdefault(rule.id, RateLimiter(rule.speed_limit_mbps))
                await asyncio.gather(
                    self.pipe(rule, reader, target_writer, "up", limiter),
                    self.pipe(rule, target_reader, writer, "down", limiter),
                )
            except Exception as exc:
                log.info("connection closed rule=%s sni=%s peer=%s error=%s", rule.id, rule.sni, peer, exc)
            finally:
                try:
                    writer.close()
                    await writer.wait_closed()
                except Exception:
                    pass
                try:
                    target_writer.close()  # type: ignore[name-defined]
                    await target_writer.wait_closed()  # type: ignore[name-defined]
                except Exception:
                    pass
                await self.flush_stats()

        server = await asyncio.start_server(handler, RELAY_HOST, rule.relay_port)
        self.servers[rule.id] = server
        self.rules[rule.id] = rule
        self.limiters[rule.id] = RateLimiter(rule.speed_limit_mbps)
        addrs = ", ".join(str(sock.getsockname()) for sock in server.sockets or [])
        log.info("listening rule=%s sni=%s on %s -> %s:%s speed=%sMbps quota=%sGB", rule.id, rule.sni, addrs, rule.target, rule.port, rule.speed_limit_mbps or 0, rule.traffic_limit_gb or 0)

    async def pipe(self, rule: Rule, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, direction: str, limiter: RateLimiter) -> None:
        while not reader.at_eof():
            if not await self.rule_active(rule):
                break
            data = await reader.read(BUFFER_SIZE)
            if not data:
                break
            await limiter.wait(len(data))
            writer.write(data)
            await writer.drain()
            await self.add_pending(rule.id, direction, len(data))
        try:
            writer.close()
        except Exception:
            pass

    async def reconcile(self) -> None:
        while not self.stopping.is_set():
            try:
                latest = self.load_rules()
                # Stop removed/inactive servers.
                for rid in list(self.servers.keys()):
                    if rid not in latest:
                        server = self.servers.pop(rid)
                        server.close()
                        await server.wait_closed()
                        self.rules.pop(rid, None)
                        self.limiters.pop(rid, None)
                        log.info("stopped rule=%s", rid)
                # Start new servers or restart changed ports/targets/limits.
                for rid, rule in latest.items():
                    current = self.rules.get(rid)
                    if not current:
                        await self.serve_rule(rule)
                    elif (current.relay_port, current.target, current.port, current.speed_limit_mbps, current.traffic_limit_gb) != (rule.relay_port, rule.target, rule.port, rule.speed_limit_mbps, rule.traffic_limit_gb):
                        server = self.servers.pop(rid)
                        server.close()
                        await server.wait_closed()
                        self.rules.pop(rid, None)
                        self.limiters.pop(rid, None)
                        await self.serve_rule(rule)
            except Exception as exc:
                log.error("reconcile error: %s", exc)
            await asyncio.sleep(REFRESH_INTERVAL)

    async def flusher(self) -> None:
        while not self.stopping.is_set():
            try:
                await self.flush_stats()
            except Exception as exc:
                log.error("flush error: %s", exc)
            await asyncio.sleep(FLUSH_INTERVAL)

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                loop.add_signal_handler(sig, self.stopping.set)
            except NotImplementedError:
                pass
        await self.reconcile_once()
        tasks = [asyncio.create_task(self.reconcile()), asyncio.create_task(self.flusher())]
        await self.stopping.wait()
        for task in tasks:
            task.cancel()
        await self.flush_stats()
        for server in self.servers.values():
            server.close()
            await server.wait_closed()
        log.info("relay stopped")

    async def reconcile_once(self) -> None:
        latest = self.load_rules()
        for rule in latest.values():
            try:
                await self.serve_rule(rule)
            except OSError as exc:
                log.error("cannot listen rule=%s port=%s error=%s", rule.id, rule.relay_port, exc)


async def main() -> None:
    mgr = RelayManager()
    await mgr.run()


if __name__ == "__main__":
    asyncio.run(main())
