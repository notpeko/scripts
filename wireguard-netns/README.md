# wireguard-netns

Runs a wireguard tunnel under an unprivileged network namespace.

## Dependencies

- `unshare`
- `slirp4netns`
- `wg`

## Usage

Use `wg-netns <wg-quick configuration file> <command> [args]` to run `command` inside
a network namespace with the given wireguard configuration.

Additional behavior can be changed with the following environment variables:

- `WG_BYPASS_IPS`: comma separated list of IPs that should be routed outside the wireguard tunnel, defaults to nothing
- `SLIRP_INTERFACE`: network interface to be used for the slirp interface, defaults to `eth69`
- `WG_INTERFACE`: network interface to be used for the wireguard tunnel, defaults to `wg69`
- `WG_PREVENT_BYPASS`: if set to `0`, runs the given program in the same namespace as the wireguard tunnel, otherwise a second namespace is ran to isolate it from being able to reconfigure/bypass wireguard, defaults to `1`

