#!/bin/sh
# Собирает архив мода для игроков: .build/BaseStationStorage-<версия>.zip
#
# В пакете лежит ровно то же дерево common/, что уезжает на сервер, плюс УСТАНОВКА.txt.
# Отдельной «клиентской сборки» нет: игра сама выбирает, что исполнять, по каталогу
# (media/lua/client, media/lua/server, media/lua/shared).
#
# zip-бинарника на этом хосте нет, поэтому архив кладёт python3 stdlib zipfile.
set -eu

cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/^modversion=//p' common/mod.info | tr -d '[:space:]')
if [ -z "$VERSION" ]; then
    echo "ОШИБКА: в common/mod.info нет modversion" >&2
    exit 1
fi

OUT=".build/BaseStationStorage-$VERSION.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM

mkdir -p "$STAGE/BaseStationStorage"
cp -R common "$STAGE/BaseStationStorage/common"

cat > "$STAGE/BaseStationStorage/УСТАНОВКА.txt" <<EOF
Base Station Storage $VERSION — мод для Project Zomboid Build 42

УСТАНОВКА
1. Закройте игру.
2. Скопируйте папку BaseStationStorage целиком в каталог модов игры:
   Windows: C:\\Users\\<ваш пользователь>\\Zomboid\\mods\\
   Linux:   ~/Zomboid/mods/
   Структура должна получиться такой: ...\\Zomboid\\mods\\BaseStationStorage\\common\\mod.info
   (каталог common обязателен: без него игра мод не увидит).
3. Запустите игру и подключитесь к серверу. Мод включится сам — сервер его требует,
   в списке модов он подписан как "Base Station Storage".

КАК ПОЛЬЗОВАТЬСЯ
- ПКМ по ящику, холодильнику или шкафчику внутри своего убежища -> "База" ->
  "Добавить в базу". Регистрировать может владелец убежища, его жители, админ и модератор.
- Крафт и готовка видят содержимое добавленных хранилищ, ПОКА вы находитесь внутри
  своего убежища. Вышли за границу — хранилища базы перестают учитываться.
  Правило одинаково для всех, включая админов.
- "Разложить по базе" на контейнере или "Разложить инвентарь по базе" в меню инвентаря
  раскладывает вещи по хранилищам: сначала туда, где такой предмет уже лежит.
- У каждого контейнера две роли: "Давать ингредиенты" и "Принимать при раскладке".
- "Показать список базы" печатает список контейнеров в консоль клиента.

ЕСЛИ СЕРВЕР ОТКАЗЫВАЕТ
- "База: хранилища доступны только внутри убежища" — вы вышли за границу сейфхауса.
- "База: этот контейнер не из базы и слишком далеко" — контейнер не зарегистрирован.
Недоступные хранилища не ломают крафт: они просто не участвуют, а в лог сервера
пишется строка "craft source dropped".

Версия мода должна совпадать с серверной: $VERSION.
EOF

mkdir -p .build
rm -f "$OUT"

python3 - "$STAGE" "$OUT" <<'PY'
import os
import sys
import zipfile

stage, out = sys.argv[1], sys.argv[2]
count = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for base, _dirs, files in os.walk(stage):
        for name in sorted(files):
            path = os.path.join(base, name)
            archive.write(path, os.path.relpath(path, stage))
            count += 1
print(f"файлов в архиве: {count}")
PY

echo "архив: $OUT ($(wc -c < "$OUT") байт, версия $VERSION)"
echo "--- содержимое:"
unzip -l "$OUT" | awk 'NR>3 && $4!=""{print "  "$4}'