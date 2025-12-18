#!/usr/bin/env bash
set -euo pipefail

log(){ printf "\n>>> %s\n" "$*"; }
warn(){ printf "\n⚠️  %s\n" "$*"; }
die(){ printf "\n❌ %s\n" "$*"; exit 1; }

# Must be run as normal user, not root
if [[ "${EUID}" -eq 0 ]]; then
  die "Run as your normal user (not root). The script uses sudo."
fi

command -v sudo >/dev/null 2>&1 || die "sudo not found. Install sudo first."
sudo -v

USER_NAME="$(id -un)"
HOME_DIR="$HOME"

log "User: $USER_NAME"
log "Debian: $(cat /etc/debian_version 2>/dev/null || echo unknown)"

log "Installing prerequisites"
sudo apt update
sudo apt install -y curl wget ca-certificates gpg git

############################################
# 1) Enable contrib / non-free properly
############################################
log "Enabling contrib/non-free/non-free-firmware (deb822 + sources.list supported)"

# deb822 default on Debian 13
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
  log "Detected /etc/apt/sources.list.d/debian.sources (deb822) — editing Components:"
  sudo cp -a /etc/apt/sources.list.d/debian.sources \
    "/etc/apt/sources.list.d/debian.sources.bak.$(date +%F-%H%M%S)"

  # Replace Components lines to include needed components
  sudo awk '
    BEGIN{changed=0}
    /^Components:/{
      print "Components: main contrib non-free non-free-firmware";
      changed=1; next
    }
    {print}
    END{
      if(changed==0){
        # If file had no Components line, do nothing (rare)
      }
    }
  ' /etc/apt/sources.list.d/debian.sources | sudo tee /etc/apt/sources.list.d/debian.sources >/dev/null

else
  log "No deb822 debian.sources found — editing /etc/apt/sources.list"
  if [[ -f /etc/apt/sources.list ]]; then
    sudo cp -a /etc/apt/sources.list \
      "/etc/apt/sources.list.bak.$(date +%F-%H%M%S)"
    # Add contrib/non-free/non-free-firmware after main if missing
    sudo sed -i 's/^\(\s*deb\s\+\S\+\s\+\S\+\s\+main\)\(\s\+.*\)*$/\1 contrib non-free non-free-firmware/g' /etc/apt/sources.list
  else
    warn "Neither debian.sources nor sources.list found. You may be using a custom APT layout."
  fi
fi

sudo apt update
sudo apt full-upgrade -y

############################################
# 2) Install desktop + apps
############################################
log "Installing i3 + LightDM + Xorg + apps + theming + tooling"
sudo apt install -y \
  xorg xinit dbus-x11 \
  i3-wm i3status i3lock \
  lightdm lightdm-gtk-greeter \
  network-manager network-manager-gnome \
  pulseaudio pavucontrol \
  feh lxappearance \
  kitty thunar thunar-archive-plugin file-roller \
  polybar rofi picom \
  eog flameshot libreoffice hexchat \
  gvfs gvfs-backends xdg-utils \
  autorandr arandr stow \
  arc-theme papirus-icon-theme breeze-cursor-theme \
  fonts-jetbrains-mono fonts-font-awesome fonts-noto fonts-noto-color-emoji \
  unzip

log "Enabling services (LightDM + NetworkManager)"
sudo systemctl enable NetworkManager
sudo systemctl enable lightdm

############################################
# 3) NVIDIA driver (Debian way) + Optimus wiring
############################################
log "Installing NVIDIA driver (Debian packages) + headers"
sudo apt install -y nvidia-driver firmware-misc-nonfree linux-headers-amd64

log "Enable NVIDIA DRM modeset (good for modern compositing)"
sudo install -d /etc/modprobe.d
sudo tee /etc/modprobe.d/nvidia.conf >/dev/null <<'EOF'
options nvidia-drm modeset=1
EOF

# IMPORTANT: Do NOT force a global Xorg NVIDIA Device section on Optimus laptops here.
# That’s a common cause of display-manager login hangs.
if [[ -f /etc/X11/xorg.conf.d/20-nvidia.conf ]]; then
  warn "Found /etc/X11/xorg.conf.d/20-nvidia.conf — disabling to avoid Optimus login issues."
  sudo mv /etc/X11/xorg.conf.d/20-nvidia.conf /etc/X11/xorg.conf.d/20-nvidia.conf.disabled.$(date +%F-%H%M%S)
fi

log "Creating prime-run helper (run apps on NVIDIA on demand)"
sudo tee /usr/local/bin/prime-run >/dev/null <<'EOF'
#!/bin/sh
exec env __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only "$@"
EOF
sudo chmod +x /usr/local/bin/prime-run

############################################
# 4) Dotfiles + configs (stow-based)
############################################
DOTFILES="$HOME_DIR/dotfiles"
log "Setting up dotfiles repo at: $DOTFILES"
mkdir -p "$DOTFILES"
cd "$DOTFILES"
if [[ ! -d .git ]]; then
  git init
fi

mkdir -p \
  i3/.config/i3 \
  kitty/.config/kitty \
  picom/.config/picom \
  polybar/.config/polybar \
  gtk/.config/gtk-3.0 \
  bin/.local/bin \
  autorandr/.config/autorandr/postswitch.d

# display-setup fallback
log "Writing display-setup (fallback multi-monitor)"
cat > "$DOTFILES/bin/.local/bin/display-setup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
INTERNAL="$(xrandr --query | awk '/ connected/ {print $1}' | grep -E '^(eDP|LVDS)' | head -n1 || true)"
EXTERNAL="$(xrandr --query | awk '/ connected/ {print $1}' | grep -vE '^(eDP|LVDS)' | head -n1 || true)"
if [[ -n "${EXTERNAL}" && -n "${INTERNAL}" ]]; then
  xrandr --output "${EXTERNAL}" --primary --auto \
         --output "${INTERNAL}" --auto --left-of "${EXTERNAL}"
elif [[ -n "${EXTERNAL}" ]]; then
  xrandr --output "${EXTERNAL}" --primary --auto
elif [[ -n "${INTERNAL}" ]]; then
  xrandr --output "${INTERNAL}" --primary --auto
fi
EOF
chmod +x "$DOTFILES/bin/.local/bin/display-setup"

# autorandr post-switch hook to refresh bar
log "Writing autorandr postswitch hook"
cat > "$DOTFILES/autorandr/.config/autorandr/postswitch.d/10-reload-i3-polybar" <<'EOF'
#!/usr/bin/env bash
pkill -x polybar || true
sleep 0.2
~/.config/polybar/launch.sh >/dev/null 2>&1 &
i3-msg reload >/dev/null 2>&1 || true
EOF
chmod +x "$DOTFILES/autorandr/.config/autorandr/postswitch.d/10-reload-i3-polybar"

# picom tuned (safe)
log "Writing picom config"
cat > "$DOTFILES/picom/.config/picom/picom.conf" <<'EOF'
backend = "glx";
vsync = true;
use-damage = true;
xrender-sync-fence = true;

inactive-opacity = 0.95;
frame-opacity = 0.95;

opacity-rule = [
  "90:class_g = 'kitty'",
  "90:class_g = 'Thunar'",
  "90:class_g = 'Rofi'"
];

shadow = true;
shadow-radius = 12;
shadow-offset-x = -6;
shadow-offset-y = -6;
shadow-opacity = 0.45;

shadow-exclude = [
  "class_g = 'Polybar'",
  "window_type = 'dock'",
  "window_type = 'desktop'"
];

corner-radius = 8;
rounded-corners-exclude = [
  "class_g = 'Polybar'",
  "window_type = 'dock'",
  "window_type = 'desktop'"
];

blur-method = "none";
EOF

# GTK theming defaults
log "Writing GTK theme defaults"
cat > "$DOTFILES/gtk/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Arc-Dark
gtk-icon-theme-name=Papirus-Dark
gtk-cursor-theme-name=Breeze
gtk-font-name=Noto Sans 10
gtk-application-prefer-dark-theme=1
EOF

cat > "$DOTFILES/gtk/.gtkrc-2.0" <<'EOF'
gtk-theme-name="Arc-Dark"
gtk-icon-theme-name="Papirus-Dark"
gtk-cursor-theme-name="Breeze"
gtk-font-name="Noto Sans 10"
EOF

# Kitty
log "Writing kitty config"
cat > "$DOTFILES/kitty/.config/kitty/kitty.conf" <<'EOF'
font_family JetBrains Mono
font_size 11
background_opacity 0.90
enable_audio_bell no
EOF

# Polybar
log "Writing polybar launcher + example config"
cp -f /usr/share/doc/polybar/examples/config.ini "$DOTFILES/polybar/.config/polybar/config.ini" 2>/dev/null || true
cat > "$DOTFILES/polybar/.config/polybar/launch.sh" <<'EOF'
#!/usr/bin/env bash
killall -q polybar || true
polybar main &
EOF
chmod +x "$DOTFILES/polybar/.config/polybar/launch.sh"

# i3 config (note: $mod+e for thunar, not $mod+f)
log "Writing i3 config"
cat > "$DOTFILES/i3/.config/i3/config" <<'EOF'
set $mod Mod4
font pango:JetBrains Mono 10

# Apps
bindsym $mod+Return exec kitty
bindsym $mod+d exec rofi -show drun
bindsym $mod+e exec thunar
bindsym Print exec flameshot gui

# Multi-monitor: autorandr first, fallback
bindsym $mod+Shift+m exec --no-startup-id sh -lc "autorandr --change --force || ~/.local/bin/display-setup"
exec --no-startup-id sh -lc "autorandr --change --force || ~/.local/bin/display-setup"

# Compositor
exec --no-startup-id picom --experimental-backends --config ~/.config/picom/picom.conf

# Bar
exec --no-startup-id ~/.config/polybar/launch.sh

# Network tray
exec --no-startup-id nm-applet

# Wallpaper (optional)
exec --no-startup-id sh -lc '[ -f ~/Pictures/wallpaper.jpg ] && feh --bg-scale ~/Pictures/wallpaper.jpg'

# Basics
bindsym $mod+Shift+q kill
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exit
EOF

############################################
# 5) Optimus X wiring: reverse PRIME on login
############################################
log "Writing ~/.xprofile (Optimus-safe provider wiring + display setup)"
cat > "$HOME_DIR/.xprofile" <<'EOF'
#!/bin/sh
# Optimus / external outputs: make NVIDIA outputs available (common on laptops where HDMI/DP are wired to NVIDIA)
# Try common provider names; ignore errors if not present.
xrandr --setprovideroutputsource modesetting NVIDIA-0 2>/dev/null || true
xrandr --setprovideroutputsource modesetting NVIDIA-G0 2>/dev/null || true
xrandr --auto

# Apply a simple external-monitor layout if present
~/.local/bin/display-setup 2>/dev/null || true
EOF
chmod +x "$HOME_DIR/.xprofile"

############################################
# 6) Deploy stow packages into $HOME
############################################
log "Deploying dotfiles via stow"
cd "$DOTFILES"
stow -t "$HOME_DIR" i3 kitty picom polybar gtk bin autorandr

############################################
# 7) Install VS Code (Microsoft repo)
############################################
log "Installing VS Code"
sudo install -d /usr/share/keyrings /etc/apt/sources.list.d

wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg
sudo install -D -o root -g root -m 644 /tmp/microsoft.gpg /usr/share/keyrings/microsoft.gpg
rm -f /tmp/microsoft.gpg

sudo tee /etc/apt/sources.list.d/vscode.sources >/dev/null <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64,arm64,armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF

sudo apt update
sudo apt install -y code

############################################
# 8) Finish
############################################
log "Done."
echo ""
echo "✅ COMPLETE. Next steps:"
echo "1) Reboot: sudo reboot"
echo "2) Login via LightDM, select i3"
echo "3) Create autorandr profiles (recommended):"
echo "   - With external connected: autorandr --save docked"
echo "   - Laptop only:            autorandr --save mobile"
echo ""
echo "NVIDIA offload usage examples:"
echo "  prime-run glxinfo | grep renderer"
echo "  prime-run kitty"
echo ""
echo "If LightDM still hangs, from TTY run:"
echo "  journalctl -b -u lightdm --no-pager | tail -200"
echo "  tail -200 /var/log/Xorg.0.log"
