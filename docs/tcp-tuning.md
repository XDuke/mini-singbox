# TCP tuning

mini-singbox performs a conservative, offline TCP tuning pass after a successful
deployment unless `MINI_SINGBOX_AUTO_TUNE=0` is set. The implementation follows:

```text
detect -> derive -> plan -> apply -> verify -> rollback
```

No speed test, ping, DNS query, package download, kernel replacement, module
load, route change, firewall change, or traffic-control command is performed.

## Protocol boundary

- VLESS Reality and AnyTLS are TCP workloads and may receive safe-core tuning.
- Hysteria2 is UDP/QUIC. TCP congestion control and TCP buffers are never
  described as Hysteria2 optimizations.
- A Hysteria2-only server produces `SKIP` actions and no tuning state.

## Detection

`mini-singbox tune detect` reads local files only. It reports distribution,
kernel, architecture, best-effort virtualization, visible memory, cgroup v1/v2
memory limit, effective memory, CPU affinity, default route interface, MTU,
current sysctls, registered congestion controls, and write capability.

Effective memory is the smallest valid value from visible RAM and every active
cgroup ancestor limit. `memory.max=max`, missing files, permission failures,
and very large unlimited sentinel values safely fall back to visible RAM.
Buffer tuning is disabled when memory is unknown.

## Automatic plan

Only `HIGH` confidence `SET` actions are applied:

| Key | Automatic condition | Otherwise |
|---|---|---|
| `net.core.default_qdisc=fq` | fq is built in or already loaded, and the sysctl is writable | `KEEP`, `MANUAL`, or `UNSUPPORTED` |
| `net.ipv4.tcp_congestion_control=bbr` | `bbr` is registered in `tcp_available_congestion_control` and writable | `KEEP` or `SKIP` |
| `net.ipv4.tcp_mtu_probing=1` | TCP is enabled and the sysctl is writable | `KEEP` or `UNSUPPORTED` |
| `net.ipv4.tcp_slow_start_after_idle` | never changed by the default policy | `KEEP` |

The kernel documents MTU probing mode `1` as disabled by default and activated
when an ICMP black hole is detected. The available-congestion-control list is
used as runtime evidence; kernel versions are never used to claim BBR2/BBRv3.
See the [Linux IP sysctl documentation](https://www.kernel.org/doc/html/latest/networking/ip-sysctl.html)
and [FQ manual](https://man7.org/linux/man-pages/man8/tc-fq.8.html).

The first release intentionally does not modify socket buffers, `tcp_mem`,
`tcp_tw_reuse`, `tcp_fin_timeout`, queue budgets, RPS/RFS, ECN, `initcwnd`,
routes, MSS, UDP settings, or `tc` shaping.

Changing `net.core.default_qdisc` does not replace the qdisc already attached to
the live interface. It becomes the default for subsequently created qdiscs and
is applied early on later boots through sysctl.d. mini-singbox deliberately does
not use `tc qdisc replace`, because doing so could overwrite provider or
administrator policy.

## Transaction and ownership

Before the first write, mini-singbox creates a mode `0600` baseline under the
root-only `/var/lib/mini-singbox/tune/`. This is intentionally outside the
service-user-owned configuration directory. It then records an `applying` transaction, writes one
sysctl at a time, reads every value back, writes the dedicated persistence file,
and changes the transaction to `active`.

The persistence file is `/etc/sysctl.d/90-mini-singbox-tune.conf`, following the
documented sysctl.d local-administrator range. It contains only parameters that
mini-singbox actually changed. See the
[systemd sysctl.d documentation](https://www.freedesktop.org/software/systemd/man/latest/sysctl.d.html).

The active state records a SHA-256 ownership hash. Verification reports drift
when a managed runtime value or file differs. Rollback restores a parameter only
when its current value still equals the mini-singbox-managed value. External
administrator or provider changes are not overwritten.

## Commands

```sh
sudo mini-singboxctl tune detect
sudo mini-singboxctl tune plan
sudo mini-singboxctl tune plan --bw 500 --rtt 80
sudo mini-singboxctl tune apply --dry-run
sudo mini-singboxctl tune apply
sudo mini-singboxctl tune verify
sudo mini-singboxctl tune status
sudo mini-singboxctl tune rollback
```

`--bw` and `--rtt` are user-supplied measurement inputs. When both are present,
the tool calculates `BDP_bytes = Mbps * milliseconds * 125`. The result is
informational and is not used to change buffers in this phase.

## Failure handling

- Unsupported or read-only container sysctls become `UNSUPPORTED`; repeated
  permission errors are not emitted.
- A failed write or failed read-back triggers recovery of values changed by the
  current transaction.
- An existing persistence file without a baseline is never treated as an
  original baseline.
- A changed persistence file or runtime value is reported as drift. Rollback
  stops rather than overwriting the external change.
- The uninstaller rolls back active tuning before removing the binary. If safe
  rollback is impossible, it keeps the program so the status can be inspected.

## Deferred work

Memory-aware buffer planning, runtime retransmission/drop metrics, RPS
recommendations, policer measurement, and shaping are not implemented. They
require separate evidence and acceptance testing before they can enter an
automatic path.
