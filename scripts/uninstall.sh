#!/bin/bash
# Удаляет приложение и агентов. Настройки/лог остаются, sudoers — командой в конце.
set -uo pipefail
label=com.mere1y.awake
uid=$(id -u)

# bootout шлёт SIGTERM — приложение само размораживает и возвращает сон.
launchctl bootout "gui/$uid/$label" 2>/dev/null
launchctl bootout "gui/$uid/$label.backstop" 2>/dev/null
bash "$HOME/Library/Application Support/Awake/backstop.sh" 2>/dev/null

rm -rf "$HOME/Applications/Awake.app" "$HOME/.local/bin/awake" \
  "$HOME/Library/LaunchAgents/$label.plist" "$HOME/Library/LaunchAgents/$label.backstop.plist"
echo "Удалено. Настройки: ~/Library/Application Support/Awake, лог: ~/Library/Logs/Awake"
[ -f /etc/sudoers.d/awake ] && echo "sudoers-правило: sudo rm /etc/sudoers.d/awake"
exit 0
