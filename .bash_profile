if [ -f "${XDG_RUNTIME_DIR}/ssh-agent.env" ]; then
            . "${XDG_RUNTIME_DIR}/ssh-agent.env"
fi
export SSH_AUTH_SOCK="$XDG_RUNTIME_DIR/ssh-agent.socket"
