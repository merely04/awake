#!/bin/bash
# Сборка и установка: ~/Applications/Awake.app, ~/.local/bin/awake, два LaunchAgent.
# sudoers-правило ставится отдельно (нужен пароль) — скрипт печатает команду.
set -euo pipefail
cd "$(dirname "$0")/.."

label=com.mere1y.awake
app="$HOME/Applications/Awake.app"
support="$HOME/Library/Application Support/Awake"
agents="$HOME/Library/LaunchAgents"
uid=$(id -u)

swift build -c release
bin=$(swift build -c release --show-bin-path)/Awake

launchctl bootout "gui/$uid/$label" 2>/dev/null || true
launchctl bootout "gui/$uid/$label.backstop" 2>/dev/null || true
# bootout асинхронный: пока старый процесс завершается, bootstrap падает с «Input/output error».
for _ in $(seq 1 50); do
  launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break
  sleep 0.2
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$support" "$HOME/.local/bin" "$HOME/Library/Logs/Awake"
cp "$bin" "$app/Contents/MacOS/Awake"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
# Регистрируем в LaunchServices, иначе macOS не даёт приложению слать уведомления.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
ln -sf "$app/Contents/MacOS/Awake" "$HOME/.local/bin/awake"
install -m 0755 scripts/backstop.sh "$support/backstop.sh"

cat > "$agents/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$app/Contents/MacOS/Awake</string><string>--app</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/Awake/stderr.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/Awake/stderr.log</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF

cat > "$agents/$label.backstop.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label.backstop</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$support/backstop.sh</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$uid" "$agents/$label.plist"
launchctl bootstrap "gui/$uid" "$agents/$label.backstop.plist"
echo "Установлено: $app, ~/.local/bin/awake"

sudoers=/etc/sudoers.d/awake
rule="$USER ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
if ! sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
  tmp=$(mktemp)
  echo "$rule" > "$tmp"
  /usr/sbin/visudo -cqf "$tmp"
  echo
  echo "Для режима «с закрытой крышкой» нужно sudoers-правило. Выполни один раз:"
  echo "  sudo install -m 0440 -o root -g wheel $tmp $sudoers"
fi
