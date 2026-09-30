# ez-ssh-agent

Long-lived **systemd user** `ssh-agent` so you unlock password-protected keys
**once per boot**. `SSH_AUTH_SOCK` comes from `environment.d`.

## Install

```bash
./install-user-unit.sh
```

That copies the unit and `environment.d` drop-in, enables the user service,
warns about linger, then runs `ssh-add`. Extra `ssh-add` args are forwarded.

Manual equivalent:

```bash
install -D -m 0644 ez-ssh-agent.service ~/.config/systemd/user/
install -D -m 0644 environment.d/ssh-agent.conf ~/.config/environment.d/
systemctl --user daemon-reload
systemctl --user enable --now ez-ssh-agent.service
export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/ssh-agent.socket
ssh-add
```

## Linger (summary)

Without linger, logout stops the user manager — the agent dies and unlocked
keys are gone. With `loginctl enable-linger $USER`, the agent (and unlocked
keys) stay until reboot; anything that can reach the agent socket can use them.
This project does **not** enable linger for you.

## systemctl --user

```bash
systemctl --user enable --now ez-ssh-agent.service
systemctl --user status ez-ssh-agent.service
systemctl --user restart ez-ssh-agent.service
systemctl --user stop ez-ssh-agent.service
systemctl --user disable ez-ssh-agent.service
```

Restart clears loaded keys; run `ssh-add` again afterward.

## environment.d

`~/.config/environment.d/ssh-agent.conf` sets:

```text
SSH_AUTH_SOCK=${XDG_RUNTIME_DIR}/ssh-agent.socket
```

New logins pick this up (systemd user environment). The install shell exports
it for the current session only.

## Goal

One unlock per boot: agent socket under `$XDG_RUNTIME_DIR`, keys stay loaded
until reboot (or until the service stops / linger is off and you log out).

## License

MIT License; see [LICENSE](LICENSE).
