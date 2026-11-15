#!/usr/bin/env python3
"""Stand between joiners and a host on one machine and make the link worse.

Every UDP packet is passed on after DELAY ms (plus up to JITTER ms more, so
packets can overtake each other) and LOSS percent of them are dropped, in each
direction. A joiner connects to LISTEN instead of the host's port.

  tools/net_delay_proxy.py LISTEN_PORT HOST_PORT DELAY_MS [JITTER_MS [LOSS_PERCENT]]

Each connection reaches the host from a port of its own, as it would over a
real network (a joiner makes two: one to fetch the host's certificate, one to
join). Used by tools/net_delay_check.sh.
"""
import asyncio
import random
import sys


class Front(asyncio.DatagramProtocol):
    """The port joiners talk to."""

    def __init__(self, proxy):
        self.proxy = proxy

    def connection_made(self, transport):
        self.proxy.front = transport

    def datagram_received(self, data, addr):
        asyncio.ensure_future(self.proxy.from_joiner(data, addr))


class Back(asyncio.DatagramProtocol):
    """One connection's port towards the host."""

    def __init__(self, proxy, joiner):
        self.proxy = proxy
        self.joiner = joiner

    def datagram_received(self, data, addr):
        self.proxy.later(lambda: self.proxy.front.sendto(data, self.joiner))


class Proxy:
    def __init__(self, host_port, delay, jitter, loss):
        self.host = ("127.0.0.1", host_port)
        self.delay, self.jitter, self.loss = delay / 1000.0, jitter / 1000.0, loss / 100.0
        self.front = None
        self.backs = {}   # joiner address -> transport towards the host (a future while it opens)

    def later(self, send):
        if random.random() >= self.loss:
            asyncio.get_running_loop().call_later(self.delay + random.random() * self.jitter, send)

    async def from_joiner(self, data, addr):
        if addr not in self.backs:
            loop = asyncio.get_running_loop()
            self.backs[addr] = asyncio.ensure_future(loop.create_datagram_endpoint(lambda: Back(self, addr), remote_addr=self.host))
        back, _ = await self.backs[addr]
        self.later(lambda: back.sendto(data))


async def main():
    listen, host_port, delay = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
    jitter = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    loss = float(sys.argv[5]) if len(sys.argv) > 5 else 0.0
    proxy = Proxy(host_port, delay, jitter, loss)
    await asyncio.get_running_loop().create_datagram_endpoint(lambda: Front(proxy), local_addr=("127.0.0.1", listen))
    print(f"proxy :{listen} -> :{host_port}  {delay:.0f} ms each way, jitter {jitter:.0f} ms, loss {loss:.0f}%", flush=True)
    await asyncio.Event().wait()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
