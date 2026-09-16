#!/usr/bin/env python3
"""
hold-tunnels.py — hold N simultaneous tunnels open through the VIP and report
how many established.

WHY THIS EXISTS
  Brief §15 requires 10,000 SIMULTANEOUS tunnels, and §17 asks what holding
  them costs (FDs, sockets, conntrack, memory...). That requirement is about
  connections held OPEN at the same instant -- not about request throughput.

  The Go client's `-persistent` flag is one way to hold a CONNECT tunnel open,
  but it is not the only way, and `-mode=tls` has no equivalent. Rather than
  change the client, this probe measures the requirement directly: open N
  tunnels, keep them open, report how many survived.

  It is complementary to the client, not a replacement. The client measures
  REQUEST THROUGHPUT on established tunnels; this measures CONCURRENCY and the
  setup success rate. Do not quote one as the other.

WHAT A "TUNNEL" IS IN EACH ARCHITECTURE
  CURRENT (mode=connect): TCP to VIP:CLIENT_PORT, send
      CONNECT <device>:443, expect "200 Connection established", then run the
      end-to-end mTLS handshake through the tunnel to the device. HAProxy and
      Squid carry it; the TLS is between this probe and the IoT Mock.
  TARGET (mode=tls): TCP to VIP:IOT_MOCK_PORT and the mTLS handshake directly,
      with SNI = <device>. HAProxy reads the SNI, resolves it, validates the
      resolved address, and forwards the raw TLS.

  Note the handshake is END-TO-END in both cases, so the IoT Mock performs N
  handshakes either way. The difference under test is how many tunnels the
  PROXY LAYER can hold open at once.

USAGE
  hold-tunnels.py --vip 172.28.0.10 --port 38888 --mode connect \
      --count 10000 --hold 30 \
      --cert /pki/clients/client-valid.crt --key /pki/clients/client-valid.key \
      --ca /pki/ca/ca.crt --device-fmt iot%07d.test.domain

Output: one JSON object on stdout.
"""

import argparse
import asyncio
import json
import random
import ssl
import sys
import time


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--vip", required=True)
    p.add_argument("--port", required=True, type=int)
    p.add_argument("--mode", required=True, choices=["connect", "tls"])
    p.add_argument("--count", type=int, default=10000, help="tunnels to hold open")
    p.add_argument("--hold", type=float, default=30.0, help="seconds to hold them")
    p.add_argument("--device-fmt", default="iot%07d.test.domain")
    p.add_argument("--device-count", type=int, default=1000000)
    p.add_argument("--cert", required=True)
    p.add_argument("--key", required=True)
    p.add_argument("--ca", required=True)
    p.add_argument("--stagger-ms", type=float, default=0.0,
                   help="delay between connection starts, to avoid a handshake thundering herd")
    p.add_argument("--setup-timeout", type=float, default=30.0)
    p.add_argument("--label", default="hold")
    p.add_argument("--body-bytes", type=int, default=256)
    p.add_argument("--method", default="PUT")
    p.add_argument("--path", default="/")
    p.add_argument("--no-prime", action="store_true",
                   help="skip the priming request (diagnostic only: see PRIMING below)")
    return p.parse_args()


# ---------------------------------------------------------------------------
# PRIMING, AND WHY IT IS NOT OPTIONAL
#
# The IoT Mock's HTTP server sets ReadHeaderTimeout to 10s: a connection that
# has completed its TLS handshake but sent no request headers is CLOSED after
# ten seconds. IdleTimeout is 90s, so once one request has been sent the tunnel
# survives idle for a minute and a half.
#
# So "hold 10,000 tunnels open" is not achievable by opening 10,000 sockets and
# waiting -- the backend will reap them. Each tunnel must carry at least one
# request to become holdable. That is also the realistic shape: an IoT device
# tunnel exists because the device exchanges data over it, not as an idle socket.
#
# Measured before priming was added: 200/200 established, then 0/200 alive at
# t=10s. After priming, tunnels survive the hold window.
# ---------------------------------------------------------------------------
async def send_put(reader, writer, a, device):
    """One request/response over an established tunnel, leaving it reusable."""
    body = b"x" * a.body_bytes
    head = (
        f"{a.method} {a.path} HTTP/1.1\r\n"
        f"Host: {device}\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: keep-alive\r\n\r\n"
    ).encode()
    writer.write(head + body)
    await writer.drain()

    # Read status line + headers, then exactly Content-Length bytes of body, so
    # the connection is left correctly framed for reuse.
    status_line = await asyncio.wait_for(reader.readline(), timeout=a.setup_timeout)
    if not status_line:
        raise RuntimeError("eof_before_status")
    status = int(status_line.split()[1])
    length = 0
    while True:
        line = await asyncio.wait_for(reader.readline(), timeout=a.setup_timeout)
        if line in (b"\r\n", b"\n", b""):
            break
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1].strip())
    if length:
        await asyncio.wait_for(reader.readexactly(length), timeout=a.setup_timeout)
    return status


def make_ctx(a):
    ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=a.ca)
    ctx.load_cert_chain(a.cert, a.key)
    ctx.check_hostname = True
    return ctx


async def open_connect_tunnel(a, device, ctx):
    """CURRENT: CONNECT through the proxy, then TLS inside the tunnel."""
    reader, writer = await asyncio.open_connection(a.vip, a.port)
    try:
        req = f"CONNECT {device}:443 HTTP/1.1\r\nHost: {device}:443\r\n\r\n"
        writer.write(req.encode())
        await writer.drain()
        status = await asyncio.wait_for(reader.readline(), timeout=a.setup_timeout)
        if b"200" not in status:
            return None, f"connect_refused:{status.decode(errors='replace').strip()[:80]}"
        # Drain any remaining headers up to the blank line.
        while True:
            line = await asyncio.wait_for(reader.readline(), timeout=a.setup_timeout)
            if line in (b"\r\n", b"\n", b""):
                break
        # Now the end-to-end mTLS handshake, THROUGH the tunnel.
        await asyncio.wait_for(
            writer.start_tls(ctx, server_hostname=device), timeout=a.setup_timeout)
        return (reader, writer), None
    except Exception as e:
        try:
            writer.close()
        except Exception:
            pass
        return None, f"{type(e).__name__}:{str(e)[:60]}"


async def open_tls_tunnel(a, device, ctx):
    """TARGET: direct mTLS to the VIP, SNI carries the device name."""
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(a.vip, a.port, ssl=ctx, server_hostname=device),
            timeout=a.setup_timeout)
        return (reader, writer), None
    except Exception as e:
        return None, f"{type(e).__name__}:{str(e)[:60]}"


async def main():
    a = parse_args()
    ctx = make_ctx(a)
    opener = open_connect_tunnel if a.mode == "connect" else open_tls_tunnel

    t0 = time.time()
    tunnels = []          # (reader, writer, device) — held open at the end
    failures = {}
    primed = 0
    prime_fail = {}
    lock = asyncio.Lock()
    sem = asyncio.Semaphore(500)  # bound in-flight handshakes

    async def one(i):
        nonlocal primed
        if a.stagger_ms:
            await asyncio.sleep((i * a.stagger_ms) / 1000.0)
        device = a.device_fmt % random.randint(1, a.device_count)
        async with sem:
            conn, err = await opener(a, device, ctx)
        if conn is None:
            async with lock:
                key = err.split(":")[0]
                failures[key] = failures.get(key, 0) + 1
            return
        r, w = conn
        # PRIME IMMEDIATELY, in the same task, before moving on to the next
        # tunnel. Priming in a second pass after all 10,000 are up is WRONG:
        # the backend's ReadHeaderTimeout is 10s, and establishing 10,000
        # tunnels took 20s, so the early ones are reaped before the second pass
        # reaches them. Measured with the two-pass version: 10,000 established
        # but only 4,475 primed -- which measured the probe's ordering, not the
        # proxy. One tunnel is only "held" once it carries a request.
        if not a.no_prime:
            try:
                st = await asyncio.wait_for(send_put(r, w, a, device),
                                            timeout=a.setup_timeout)
                if st == 200:
                    primed += 1
                else:
                    prime_fail[f"http_{st}"] = prime_fail.get(f"http_{st}", 0) + 1
            except Exception as e:
                k = type(e).__name__
                prime_fail[k] = prime_fail.get(k, 0) + 1
                try:
                    w.close()
                except Exception:
                    pass
                return
        tunnels.append((r, w, device))

    try:
        await asyncio.gather(*(one(i) for i in range(a.count)))
        established = len(tunnels)
        setup_seconds = time.time() - t0
        print(f"[hold] established {established}/{a.count} in {setup_seconds:.1f}s",
              file=sys.stderr, flush=True)

        # Priming happens inline in one(); by here every held tunnel already
        # carries one completed request.
        print(f"[hold] primed {primed}/{a.count} in {time.time()-t0:.1f}s",
              file=sys.stderr, flush=True)

        # Hold them open. Report survival periodically so a mid-run collapse is
        # visible rather than being averaged away.
        deadline = time.time() + a.hold
        samples = []
        while time.time() < deadline:
            await asyncio.sleep(5)
            alive = sum(1 for _, w, _ in tunnels if not w.is_closing())
            samples.append({"t": round(time.time() - t0, 1), "alive": alive})
            print(f"[hold] t={samples[-1]['t']}s alive={alive}", file=sys.stderr, flush=True)
    finally:
        for _, w, _ in tunnels:
            try:
                w.close()
            except Exception:
                pass
        await asyncio.sleep(0.5)

    result = {
        "label": a.label,
        "mode": a.mode,
        "proxy": f"{a.vip}:{a.port}",
        "requested": a.count,
        "established": established,
        "primed": primed,
        "primed_failures": prime_fail,
        "setup_seconds": round(setup_seconds, 2),
        "hold_seconds": a.hold,
        "failures": failures,
        "survival_samples": samples,
        "min_alive_during_hold": min((s["alive"] for s in samples), default=None),
    }
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
