# Cloud Terminal Demo (for `tty-fwd`)

Bridges a device terminal stream (delivered over SSH by `tty-fwd`) to a browser
terminal (xterm.js over WebSocket). The web UI lives here on the cloud side; the
device only makes an outbound SSH connection and opens **no local port**.

```
browser ──WS──► this demo (HTTP+WS) ──┐
                                       │ pairs
device: /bin/sh ─PTY─ tty-fwd ─SSH─► dropbear ─► 127.0.0.1:9000 (this demo TCP)
```

## Run

```sh
cd examples/cloud-terminal
npm install
node server.js            # UI on :8080, device stream on 127.0.0.1:9000
```

Options: `--http <port>` (browser UI), `--tcp <port>` (device stream target,
must match the device's `-B`), `--host <addr>` (TCP bind, default 127.0.0.1).

Open <http://localhost:8080/>.

## Quick local test (no SSH needed)

Simulate the device side with `socat`, connecting a local PTY shell straight to
the demo's TCP port:

```sh
socat exec:'/bin/sh -i',pty,setsid,ctty,stderr tcp:127.0.0.1:9000
```

Then open the browser UI — you should get an interactive shell. This verifies
the WebSocket/xterm path end to end.

## Full test with the real tunnel

On the cloud host run a dropbear server and this demo. On the device:

```sh
dropbearmulti tty-fwd --shell /bin/sh \
  -y -i /factory/tunnel_key \
  -B 127.0.0.1:9000 \
  tunnel@cloud-host
```

`-B 127.0.0.1:9000` tells the cloud dropbear to connect to this demo's TCP
listener; the PTY stream is bridged to whichever browser is connected.

## Notes / limitations

- Raw byte stream only: terminal **resize is not propagated** to the device PTY
  (xterm fits the browser window, but the remote PTY keeps the size `tty-fwd`
  allocated). Adding a small control channel is a possible future enhancement.
- FIFO pairing: one device socket is paired with one browser. For multiple
  devices you would add session IDs / routing.
- For production, terminate TLS (wss://) and authenticate the browser side at
  the cloud; restrict the TCP listener to localhost and only reachable via SSH.
