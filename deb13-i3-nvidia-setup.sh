#!/usr/bin/env bash
set -euo pipefail

# ---- Helpers ----
log(){ printf "\n>>> %s\n" "$*"; }
need_root(){ if [[ $EUID -ne 0 ]]; then echo "Run as your normal user; script uses sudo."; exit 1; fi; }

# Must be run as normal user, not root
if [[ "${EUID}" -eq 0 ]]; then
  echo "Please run as your normal user (not root)."
  exit 1
fi

USER_NAME="$(id -un)"
HOME_DIR="$HOME"
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"

log "User: $USER_NAME"
log "Debian codename: ${CODENAME:-unknown}"

# ---- 0) Prereqs ----
log "Installing prerequisites"
sudo apt update
sudo apt install -y sudo curl wget gpg git ca-certificates

# ---- 1) Enable contrib/non-free/non-free-firmware ----
log "Enabling contrib/non-free/non-free-firmware in /etc/apt/sources.list"
sudo sed -i 's/^[[:space:]]*deb \(.*\) main[[:space:]]*$/deb \1 main contrib non-free non-free-firmware/g' /etc/apt/sources.list
sudo sed -i 's/^[[:space:]]*deb \(.*\) main[[:space:]]*contrib.*$/deb \1 main contrib non-free non-free-firmware/g' /etc/apt/sources.list || true

sudo apt update
sudo apt full-upgrade -y

# ---- 2) Install Desktop + Apps + Tools ----
log "Installing i3 + Xorg + DM + apps + theming + multi-monitor tools"
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

log "Enable services"
sudo systemctl enable lightdm NetworkManager

# ---- 3) NVIDIA Optimus + Performance Mode ----
log "Installing NVIDIA + PRIME"
sudo apt install -y nvidia-driver nvidia-prime firmware-misc-nonfree linux-headers-amd64

log "Set PRIME to NVIDIA (performance mode)"
sudo prime-select nvidia || true

log "NVIDIA DRM modeset + tear-free Xorg options"
sudo install -d /etc/modprobe.d /etc/X11/xorg.conf.d

sudo tee /etc/modprobe.d/nvidia.conf >/dev/null <<'EOF'
options nvidia-drm modeset=1
EOF

sudo tee /etc/X11/xorg.conf.d/20-nvidia.conf >/dev/null <<'EOF'
Section "Device"
    Identifier "Nvidia Card"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration"
    Option "TripleBuffer" "true"
    Option "ForceFullCompositionPipeline" "true"
EndSection
EOF

sudo update-initramfs -u

# ---- 4) Dotfiles repo layout (stow) ----
DOTFILES="$HOME_DIR/dotfiles"

log "Creating dotfiles repo at $DOTFILES"
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
  autorandr/.config/autorandr

# ---- 5) Multi-monitor auto-detection ----
log "Writing display-setup fallback script"
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

log "Autorandr postswitch hook: restart polybar and reload i3"
mkdir -p "$DOTFILES/autorandr/.config/autorandr/postswitch.d"
cat > "$DOTFILES/autorandr/.config/autorandr/postswitch.d/10-reload-i3-polybar" <<'EOF'
#!/usr/bin/env bash
# Called by autorandr after switching layouts
pkill -x polybar || true
sleep 0.2
~/.config/polybar/launch.sh >/dev/null 2>&1 &
i3-msg reload >/dev/null 2>&1 || true
EOF
chmod +x "$DOTFILES/autorandr/.config/autorandr/postswitch.d/10-reload-i3-polybar"

# ---- 6) Picom tuned for NVIDIA ----
log "Writing picom config (NVIDIA-friendly)"
cat > "$DOTFILES/picom/.config/picom/picom.conf" <<'EOF'
backend = "glx";
vsync = true;
use-damage = true;
xrender-sync-fence = true;

inactive-opacity = 0.95;
frame-opacity = 0.95;
inactive-opacity-override = false;

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

# ---- 7) Theme pack defaults ----
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

# ---- 8) Kitty ----
log "Writing kitty config"
cat > "$DOTFILES/kitty/.config/kitty/kitty.conf" <<'EOF'
font_family JetBrains Mono
font_size 11
background_opacity 0.90
enable_audio_bell no
EOF

# ---- 9) Polybar ----
log "Writing polybar config + launcher"
cp -f /usr/share/doc/polybar/examples/config.ini "$DOTFILES/polybar/.config/polybar/config.ini" || true

cat > "$DOTFILES/polybar/.config/polybar/launch.sh" <<'EOF'
#!/usr/bin/env bash
killall -q polybar || true
polybar main &
EOF
chmod +x "$DOTFILES/polybar/.config/polybar/launch.sh"

# ---- 10) i3 ----
log "Writing i3 config"
cat > "$DOTFILES/i3/.config/i3/config" <<'EOF'
set $mod Mod4
font pango:JetBrains Mono 10

# Apps
bindsym $mod+Return exec kitty
bindsym $mod+d exec rofi -show drun
bindsym $mod+f exec thunar
bindsym Print exec flameshot gui

# Multi-monitor: autorandr first, fallback to display-setup
bindsym $mod+Shift+m exec --no-startup-id sh -lc "autorandr --change --force || ~/.local/bin/display-setup"
exec --no-startup-id sh -lc "autorandr --change --force || ~/.local/bin/display-setup"

# Compositor
exec --no-startup-id picom --experimental-backends --config ~/.config/picom/picom.conf

# Bar
exec --no-startup-id ~/.config/polybar/launch.sh

# Network tray
exec --no-startup-id nm-applet

# Wallpaper (put a file here later)
exec --no-startup-id sh -lc '[ -f ~/Pictures/wallpaper.jpg ] && feh --bg-scale ~/Pictures/wallpaper.jpg'

# i3 basics
bindsym $mod+Shift+q kill
bindsym $mod+Shift+r restart
bindsym $mod+Shift+e exit
EOF

# ---- 11) Stow everything into place ----
log "Deploying dotfiles via stow"
cd "$DOTFILES"
stow -t "$HOME_DIR" i3 kitty picom polybar gtk bin autorandr

# ---- 12) VS Code (Microsoft apt repo) ----
log "Installing VS Code from Microsoft repo"
sudo install -d /usr/share/keyrings /etc/apt/sources.list.d

# key
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /tmp/microsoft.gpg
sudo install -D -o root -g root -m 644 /tmp/microsoft.gpg /usr/share/keyrings/microsoft.gpg
rm -f /tmp/microsoft.gpg

# .sources file (modern, avoids Signed-By conflicts)
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

# ---- 13) Final ----
log "Done."
echo ""
echo "✅ COMPLETE. Next steps:"
echo "1) Reboot:   sudo reboot"
echo "2) Login via LightDM, select i3."
echo "3) Save autorandr profiles (recommended):"
echo "   - Docked (external connected): autorandr --save docked"
echo "   - Mobile (laptop only):       autorandr --save mobile"
echo "4) Put a wallpaper at: ~/Pictures/wallpaper.jpg (optional)"
echo ""
echo "Dotfiles repo: $HOME_DIR/dotfiles"
echo "To push to GitHub later (example):"
echo "  cd ~/dotfiles && git add . && git commit -m 'Debian i3 dotfiles'"
echo "  git remote add origin git@github.com:YOURUSER/dotfiles.git"
echo "  git branch -M main && git push -u origin main"

