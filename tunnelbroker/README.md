# Set up a tunnelbroker /48 on netplan

1. [create account & tunnel](https://tunnelbroker.net)
2. click `assign /48` on the tunnel page, it'll give you an address that look like `X:Y:Z::/48`, replace X:Y:Z with those numbers in the steps below
3. enable non-local binding
```sh
# enable now
sudo sysctl -w net.ipv6.ip_nonlocal_bind=1
# automatically enable on next boot
echo 'net.ipv6.ip_nonlocal_bind = 1' | sudo tee -a /etc/sysctl.conf
```
4. create the netplan configuration file (NOT in /etc/netplan)

```yml
network:
  version: 2
  tunnels:
    he-ipv6:
      mode: sit
      remote: <SERVER_IPV4>
      local: <YOUR_LOCAL_IPV4>
      addresses:
        - "X:Y:X::2/48"
      gateway6: "X:Y:Z::1"
      routes:
        - to: "::/0"
          via: "X:Y:Z::1"
          metric: 50
```

SERVER\_IPV4 is the address in the tunnelbroker page
YOUR\_LOCAL\_IPV4 is the ipv4 address the machine has on it's NIC (for servers, it's usually the public ip, but check `ip a` just in case)

5. Apply the configuration temporarily with `sudo netplan try --state /etc/netplan --config-file <path to the file you created above>`. This will automatically reset in 120 seconds.

6. In another shell, run `sudo ip -6 route replace local X:Y:Z::/48 dev lo` and test it using the `test.sh` file in this folder: `./test.sh X:Y:Z`

7. if it works, move the netplan config file to `/etc/netplan/<name>.yaml`

8. create a systemd service to run the `ip -6 route replace` command at startup

/etc/systemd/system/tunnelbroker-replace.service
```ini
[Unit]
Description=Allow nonlocal binding for tunnelbroker
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip -6 route replace local X:Y:Z::/48 dev lo

[Install]
WantedBy=multi-user.target
```
**Replace /usr/sbin/ip with the path to your `ip` executable**

9. run `sudo systemctl enable tunnelbroker-replace.service`

10. reboot

