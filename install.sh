#!/bin/sh
# Copies only this integration's files. Existing Pi integration files are replaced.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config="${XDG_CONFIG_HOME:-$HOME/.config}/${NVIM_APPNAME:-nvim}"
bindir="$HOME/.local/bin"
install -d "$config/lua/pi_nvim" "$config/lua/custom/plugins" "$config/scripts" "$bindir"
for file in "$root"/lua/pi_nvim/*.lua; do
  install -m 644 "$file" "$config/lua/pi_nvim/$(basename -- "$file")"
done
install -m 644 "$root/lua/custom/plugins/pi-nvim.lua" "$config/lua/custom/plugins/pi-nvim.lua"
install -m 755 "$root/pi_nvim.py" "$config/scripts/pi_nvim.py"
# Do not follow a legacy checkout-linked launcher and overwrite its source.
if [ -L "$bindir/pi-nvim" ]; then rm -- "$bindir/pi-nvim"; fi
install -m 755 "$root/bin/pi-nvim" "$bindir/pi-nvim"
printf 'Installed Pi integration into %s\n' "$config"
printf 'Load lua/custom/plugins/pi-nvim.lua from your config; add ~/.local/bin to PATH for the CLI.\n'
