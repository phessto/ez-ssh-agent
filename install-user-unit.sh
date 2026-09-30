#!/usr/bin/env bash
# Documented install step for the long-lived user ssh-agent.
#
# Run this instead of enabling the unit and running ssh-add by hand.
# It always reports linger and prints what that means BEFORE any key
# passphrase prompt:
#
#   1. Check linger with `loginctl show-user` and the linger-users list
#      (/var/lib/systemd/linger — one file per user with linger on).
#   2. Warn: without linger the agent dies on logout and unlocked keys
#      are lost; with linger the agent and those keys stay in memory
#      until reboot (anyone who can use the agent socket can use them).
#   3. Only then install/enable the user unit and run ssh-add.
#
# This script does not enable or disable linger. To keep the agent
# across logout, run `loginctl enable-linger` yourself (may need
# polkit) and re-run this script, or press Enter after enabling it.
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

Linger status for ${user_name}:
  loginctl show-user: ${show_user}
  linger-users (${linger_users_dir}): ${users}

WARNING — read this before any key passphrase
----------------------------------------------
Without linger:
  Logging out stops your systemd user manager. This agent stops with
  it, and keys you unlocked are wiped from memory. The next login needs
  ssh-add (and the passphrases) again.

With linger (loginctl enable-linger ${user_name}):
  The user manager and this agent keep running after logout, until
  reboot or until the service is stopped. Unlocked keys stay loaded
  in the agent's memory across logouts.
  Security implication: those keys remain usable by anything that can
  reach the agent socket until reboot — not only while you are logged
  in. Leave linger off on a shared or untrusted machine unless you
  accept that.

Either way, a reboot clears the agent. Linger is not turned on or off
by this script.
Current conclusion: linger is ${enabled}.
ENDWARN
  if [[ $enabled != yes ]]; then
    printf '\nTo enable it before unlocking keys:\n  loginctl enable-linger %s\n' "$user_name"
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
  systemctl --user enable --now ez-ssh-agent.service
}

wait_for_socket() {
  local sock=$1 i
  for i in $(seq 1 50); do
    [[ -S $sock ]] && return 0
    sleep 0.1
  done
  printf 'Agent socket did not appear at %s\n' "$sock" >&2
  systemctl --user --no-pager --full status ez-ssh-agent.service >&2 || true
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
