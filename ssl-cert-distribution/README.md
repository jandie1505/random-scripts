# SSL Certificate Distribution

Distribute TLS certificates from a central ACME host to the machines that need
them, without giving the ACME host any privileges on those machines.

A single host runs `acme.sh` and obtains certificates over DNS-01. Every other
machine fetches its own certificate over SSH on a timer and reloads whatever
consumes it. The direction matters: the ACME host holds no credentials for the
targets, so compromising it does not hand over the fleet.

## How it works

```
  ACME host                            target machine
  ---------                            --------------
  acme.sh --cron                       pull-cert.timer (hourly)
    |                                    |
    v                                    v
  /srv/certs/<target>/                 ssh -> serve-cert <target>
    fullchain.pem                        |
    privkey.pem                          v
    ^                                  validate, compare, install
    |                                    |
  sshd + forced command                  v
  serve-cert <target>  <---------------  reload service
```

### On the ACME host

```sh
install -m 0755 serve-cert /usr/local/bin/serve-cert
```

Certificates are expected under `/srv/certs/<target>/`, owned by the user
`acme.sh` runs as. Point `acme.sh` at them once per certificate:

```sh
acme.sh --install-cert -d example.net --ecc \
  --key-file       /srv/certs/proxy/privkey.pem \
  --fullchain-file /srv/certs/proxy/fullchain.pem
```

Add one `authorized_keys` entry per target machine:

```
command="/usr/local/bin/serve-cert proxy",restrict ssh-ed25519 AAAA... proxy
command="/usr/local/bin/serve-cert authentik",restrict ssh-ed25519 AAAA... authentik
```

`restrict` disables port forwarding, agent forwarding, PTY allocation and X11.
Combined with the forced command, the key can do nothing but produce a tar
archive.

The account needs a real shell for the forced command to run — `nologin` blocks
SSH entirely.

### On each target machine

```sh
install -m 0755 pull-cert /usr/local/bin/pull-cert
install -d -m 0755 /etc/pull-cert
install -m 0644 pull-cert.conf.example /etc/pull-cert/nginx.conf
install -m 0644 pull-cert@.service /etc/systemd/system/
install -m 0644 pull-cert@.timer /etc/systemd/system/
```

Generate a key for the machine and register its public half on the ACME host:

```sh
ssh-keygen -t ed25519 -f /etc/ssl/acme-pull -N '' -C "$(hostname)-acme-pull"
```

Edit `/etc/pull-cert/<profile>.conf`, then verify before automating:

```sh
pull-cert <profile> --dry-run --verbose
pull-cert <profile> --verbose
```

Once that works:

```sh
systemctl daemon-reload
systemctl enable --now pull-cert@<profile>.timer
systemctl list-timers 'pull-cert@*'
```

The profile name after the `@` is the config file name, so a machine serving
several certificates just gets several profiles and several timers.
