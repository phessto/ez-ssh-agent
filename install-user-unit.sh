#!/usr/bin/env bash
# Install the long-lived user ssh-agent, warn about linger, then ssh-add.
#
# Always reports linger and prints a short warning BEFORE any key passphrase
# prompt. Does not enable or disable linger — run `loginctl enable-linger`
# yourself if you want the agent across logout.
#
# Files installed:
#   ${XDG_CONFIG_HOME:-~/.config}/systemd/user/ez-ssh-agent.service
#   ${XDG_CONFIG_HOME:-~/.config}/environment.d/ssh-agent.conf
#
# Extra ssh-add arguments are forwarded (default: the usual identity files).
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
user_name=${USER:-$(id -un)}
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}
linger_users_dir=/var/lib/systemd/linger
unit=ez-ssh-agent.service

die() {
  printf 'install-user-unit: %s\n' "$*" >&2
  exit 1
}

# Print yes|no from `loginctl show-user -p Linger`, or "unavailable (...)".
show_user_linger() {
  local out
  if ! out=$(loginctl show-user "$user_name" -p Linger 2>&1); then
    printf 'unavailable (%s)\n' "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    return 0
  fi
  out=${out%$'\r'}
  case $out in
    Linger=yes) printf 'yes\n' ;;
    Linger=no) printf 'no\n' ;;
    *) printf 'unavailable (%s)\n' "$out" ;;
  esac
}

# linger-users: on-disk list written by `loginctl enable-linger`.
linger_users_state() {
  if [[ -e "${linger_users_dir}/${user_name}" ]]; then
    printf 'listed\n'
  elif [[ -d "$linger_users_dir" || ! -e "$linger_users_dir" ]]; then
    printf 'not listed\n'
  else
    printf 'unreadable (%s)\n' "$linger_users_dir"
  fi
}

# yes / no / unknown. Prefer an explicit show-user answer, else linger-users.
linger_enabled() {
  case $1 in
    yes) printf 'yes\n' ;;
    no) printf 'no\n' ;;
    *)
      case $2 in
        listed) printf 'yes\n' ;;
        not\ listed) printf 'no\n' ;;
        *) printf 'unknown\n' ;;
      esac
      ;;
  esac
}

print_linger_report() {
  local show_user=$1 users=$2 enabled=$3
  cat <<ENDWARN

Linger for ${user_name}: show-user=${show_user}; linger-users=${users} → ${enabled}

WARNING — before any key passphrase:
  No linger: logout stops the agent; unlocked keys are lost.
  Linger (loginctl enable-linger ${user_name}): agent + unlocked keys stay
  until reboot; anything that can reach the agent socket can use them.
This script does not change linger. Reboot always clears the agent.
ENDWARN
  if [[ $enabled != yes ]]; then
    printf 'To enable linger before unlocking: loginctl enable-linger %s\n' "$user_name"
  fi
}

confirm_before_passphrases() {
  if [[ -t 0 ]]; then
    printf '\nPress Enter to enable the user unit and then prompt for ssh-add.\n' >&2
    printf 'Ctrl-C aborts now — no key passphrase is asked until after this.\n' >&2
    read -r _
  else
    printf '\nNo terminal; continuing after the warning (stdin is not a TTY).\n' >&2
  fi
}

print_systemctl_usage() {
  cat <<ENDUSAGE

systemctl --user (after install):
  systemctl --user status ${unit}
  systemctl --user restart ${unit}   # clears loaded keys; ssh-add again
  systemctl --user stop ${unit}
  systemctl --user disable ${unit}
ENDUSAGE
}

install_units() {
  [[ -f "${repo_dir}/ez-ssh-agent.service" ]] || die "missing ${repo_dir}/ez-ssh-agent.service"
  [[ -f "${repo_dir}/environment.d/ssh-agent.conf" ]] || die "missing ${repo_dir}/environment.d/ssh-agent.conf"
  command -v systemctl >/dev/null 2>&1 || die "systemctl not found"
  command -v ssh-add >/dev/null 2>&1 || die "ssh-add not found"
  [[ -n ${XDG_RUNTIME_DIR:-} ]] || die "XDG_RUNTIME_DIR is unset; log in so the systemd user manager is running"

  install -D -m 0644 "${repo_dir}/ez-ssh-agent.service" \
    "${config_home}/systemd/user/ez-ssh-agent.service"
  install -D -m 0644 "${repo_dir}/environment.d/ssh-agent.conf" \
    "${config_home}/environment.d/ssh-agent.conf"

  systemctl --user daemon-reload
  systemctl --user enable --now "$unit"
  printf '\nEnabled and started %s:\n' "$unit"
  systemctl --user --no-pager --full status "$unit" || true
  print_systemctl_usage
}

wait_for_socket() {
  local sock=$1 i
  for i in $(seq 1 50); do
    [[ -S $sock ]] && return 0
    sleep 0.1
  done
  printf 'Agent socket did not appear at %s\n' "$sock" >&2
  systemctl --user --no-pager --full status "$unit" >&2 || true
  return 1
}

main() {
  command -v loginctl >/dev/null 2>&1 || die "loginctl not found; cannot check linger"

  local show_user users enabled
  show_user=$(show_user_linger)
  users=$(linger_users_state)
  enabled=$(linger_enabled "$show_user" "$users")
  print_linger_report "$show_user" "$users" "$enabled"
  confirm_before_passphrases

  # Linger may have been toggled after the warning, before continuing.
  show_user=$(show_user_linger)
  users=$(linger_users_state)
  enabled=$(linger_enabled "$show_user" "$users")
  printf 'Linger before unlock: %s (show-user: %s; linger-users: %s)\n' \
    "$enabled" "$show_user" "$users"

  install_units

  local sock="${XDG_RUNTIME_DIR}/ssh-agent.socket"
  wait_for_socket "$sock"
  export SSH_AUTH_SOCK=$sock

  printf '\nPrompting for key passphrases now (ssh-add). Socket: %s\n' "$SSH_AUTH_SOCK"
  printf 'New logins pick up SSH_AUTH_SOCK from environment.d. This shell does not;\n'
  printf 'export SSH_AUTH_SOCK=%q\n\n' "$SSH_AUTH_SOCK"
  ssh-add "$@"
}

main "$@"
