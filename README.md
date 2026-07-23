## Dropbear SSH
A smallish SSH server and client
https://matt.ucc.asn.au/dropbear/dropbear.html

[INSTALL.md](INSTALL.md) has compilation instructions.

[MULTI.md](MULTI.md) has instructions on making a multi-purpose binary (ie a single binary which performs multiple tasks, to save disk space).

[SMALL.md](SMALL.md) has some tips on creating small binaries.

A mirror of the Dropbear website and tarballs is available at https://dropbear.nl/mirror/.

Please contact me if you have any questions/bugs found/features/ideas/comments etc
There is also a mailing list https://lists.ucc.asn.au/mailman/listinfo/dropbear

Matt Johnston
matt@ucc.asn.au


### In the absence of detailed documentation, some notes follow

----
#### Server public key auth

You can use `~/.ssh/authorized_keys` in the same way as with OpenSSH, just put the key entries in that file.
They should be of the form:

    ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAIEAwVa6M6cGVmUcLl2cFzkxEoJd06Ub4bVDsYrWvXhvUV+ZAM9uGuewZBDoAqNKJxoIn0Hyd0NkyU99UVv6NWV/5YSHtnf35LKds56j7cuzoQpFIdjNwdxAN0PCET/MG8qyskG/2IE2DPNIaJ3Wy+Ws4IZEgdJgPlTYUBWWtCWOGc= someone@hostname

You must make sure that `~/.ssh`, and the key file, are only writable by the user.
Beware of editors that split the key into multiple lines.

Dropbear supports some options for authorized_keys entries, see the manpage.

----
#### Client public key auth

Dropbear can do public key auth as a client.
But you will have to convert OpenSSH style keys to Dropbear format, or use dropbearkey to create them.

If you have an OpenSSH-style private key `~/.ssh/id_rsa`, you need to do:

```sh
dropbearconvert openssh dropbear ~/.ssh/id_rsa  ~/.ssh/id_rsa.db
dbclient -i ~/.ssh/id_rsa.db <hostname>
```

Dropbear does not support encrypted hostkeys though can connect to ssh-agent.

----
If you want to get the public-key portion of a Dropbear private key, look at dropbearkey's `-y` option.
It will print both public key and fingerprint. If you need the pub key only you can grep by a prefix `ssh-`: 
```sh
./dropbearkey -y -f ~/.ssh/id_ed25519 | grep "^ssh-" > ~/.ssh/id_ed25519.pub
```

----
To run the server, you need to generate server keys, this is one-off:

```sh
./dropbearkey -t rsa -f dropbear_rsa_host_key
./dropbearkey -t dss -f dropbear_dss_host_key
./dropbearkey -t ecdsa -f dropbear_ecdsa_host_key
./dropbearkey -t ed25519 -f dropbear_ed25519_host_key
```

Or alternatively convert OpenSSH keys to Dropbear:

```sh
./dropbearconvert openssh dropbear /etc/ssh/ssh_host_dsa_key dropbear_dss_host_key
```

You can also get Dropbear to create keys when the first connection is made - this is preferable to generating keys when the system boots.
Make sure `/etc/dropbear/` exists and then pass `-R` to the dropbear server.

----
If the server is run as non-root, you most likely won't be able to allocate a pty, and you cannot login as any user other than that running the daemon (obviously).
Shadow passwords will also be unusable as non-root.

----
The Dropbear distribution includes a standalone version of OpenSSH's `scp` program.
You can compile it with `make scp`.
You may want to change the path of the ssh binary, specified by `_PATH_SSH_PROGRAM` in `options.h`.
By default the progress meter isn't compiled in to save space, you can enable it by adding `SCPPROGRESS=1` to the `make` commandline.


## Local build
Get the binary at `./build`
### arm 
1. `sh build.sh arm`
### arm64
1. `sh build.sh arm64`


## Fork customisations

This fork adds two compile-time options on top of upstream Dropbear. Both are
configured in `default_options.h` (or in a `localoptions.h` in the build dir)
and keep upstream behaviour unless you change them.

### Forced login shell — `DROPBEAR_FORCE_SHELL`

Normally the login shell comes from the user's `/etc/passwd` entry. Define
`DROPBEAR_FORCE_SHELL` to a path to force every interactive/exec session to use
that shell instead, regardless of the account's configured shell:

```c
#define DROPBEAR_FORCE_SHELL "/bin/sh"
```

Comment it out (leave it undefined) to keep the standard per-user shell.

### One-time / temporary password — `DROPBEAR_SVR_OTP_PASSWORD`

For appliances whose system files (`/etc/passwd`, `/etc/shadow`) are read-only,
this gives an out-of-band maintenance/recovery login without editing any system
file.

Enable it at build time (default `0` = disabled):

```c
#define DROPBEAR_SVR_OTP_PASSWORD 1
```

At runtime, set the `DROPBEAR_OTP` environment variable when starting the
server. While it holds a non-empty value, a client may authenticate **any
existing account** with that password:

```sh
DROPBEAR_OTP="$(head -c18 /dev/urandom | base64)" dropbear -F -E -p 2222
```

Behaviour and safety:

- It is an **additional** channel — the normal `/etc/shadow` check still
  applies; the OTP is only tried alongside it.
- It works even for **locked** accounts (`!` / `*` in shadow).
- The password is **constant-time compared** and **never written to logs**
  (a successful OTP login logs only `OTP auth succeeded for '<user>' from ...`).
- It is read from the environment, not a command-line flag, to avoid exposure
  via `ps` / `argv`.

Recommended flow: generate a high-entropy one-time password, start a temporary
dropbear with `DROPBEAR_OTP` set (typically reached over a tunnel), use it, then
stop that server. Keep `DROPBEAR_SVR_OTP_PASSWORD` at `0` in builds that don't
need it.

### Cloud terminal bridge — `tty-fwd`

For appliances that expose an internal shell to a cloud console over SSH without
listening on a local port. `tty-fwd` runs a shell in a PTY and connects it to
`dbclient` netcat mode (`-B`): bytes flow over an outbound SSH connection to a
TCP endpoint on the remote side (where your web UI attaches).

```sh
tty-fwd -y -i /factory/tunnel_key -B 127.0.0.1:9000 tunnel@jump.example.com
```

| Option | Meaning |
|--------|---------|
| `--shell path` | Shell to run (default: `DROPBEAR_FORCE_SHELL` or `/bin/sh`) |
| `-B host:port` | Remote TCP endpoint (on the SSH server / cloud side) |
| other flags | Passed through to `dbclient` (`-i`, `-y`, `-K`, etc.) |

The device makes no inbound connection and opens no local listen socket.
On the cloud host, something must accept connections on the forwarded port
(for example `127.0.0.1:9000` when using `-B 127.0.0.1:9000`) and bridge them
to your browser terminal.

### Device LAN dialer — `socks-fwd` (sshportal)

For embedded cameras / appliances that should expose **arbitrary** LAN
`host:port` through a cloud SOCKS endpoint (`*.proxy…`), without a Go binary.

`socks-fwd` is a thin wrapper around `dbclient` that runs the remote command
`dialer` and answers portal `CHANNEL_OPEN` of type `sshportal-dial@v1`
(payload: SSH string host + uint32 port) by dialing that address on the device
and relaying bytes — same role as `sshpc dialer`.

```sh
socks-fwd -y -i /factory/devkey -J /bin/portal-proxy -K 30 -p 443 \
  cam01@cam01.ssh.pwd.pub
```

| Option | Meaning |
|--------|---------|
| dbclient flags | `-i`, `-y`, `-J`, `-K`, `-p`, … |
| remote command | Forced to `dialer` (do not pass `-N` or `-B`) |

Pair with sshportal managed SOCKS (`egress=device`, `allowed_dest=*`) and a
notebook-side TLS unwrap (`sshpc socks up`). See sshportal `docs/socks-proxy.md`.
