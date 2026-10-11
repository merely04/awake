#!/bin/bash
# Страховка, launchd запускает раз в минуту. Если Awake.app не запущен —
# размораживает то, что он заморозил, и возвращает сон (pmset disablesleep 0).
pgrep -qx Awake && exit 0

dir="$HOME/Library/Application Support/Awake"
log="$HOME/Library/Logs/Awake/awake.log"
say() { echo "$(date +%Y-%m-%dT%H:%M:%S)$(date +%z | sed -E 's/([0-9]{2})$/:\1/') [backstop] $*" >> "$log"; }

if [ -f "$dir/frozen.pids" ]; then
  while read -r pid; do [ -n "$pid" ] && kill -CONT "$pid" 2>/dev/null; done < "$dir/frozen.pids"
  rm -f "$dir/frozen.pids"
  say "Awake не запущен — разморозил процессы из frozen.pids"
fi

if [ -f "$dir/lidstate.json" ]; then
  # Подсветку клавиатуры без приложения не вернуть (приватный API) — только звук.
  grep -q '"muted" : true' "$dir/lidstate.json" && osascript -e 'set volume output muted false'
  rm -f "$dir/lidstate.json"
  say "Awake не запущен — вернул звук по lidstate.json"
fi

if /usr/bin/pmset -g | grep -qE '^ *SleepDisabled[[:space:]]+1'; then
  if sudo -n /usr/bin/pmset -a disablesleep 0; then
    say "Awake не запущен — вернул disablesleep 0"
  else
    say "Awake не запущен, SleepDisabled=1, но sudo -n не сработал"
  fi
fi
