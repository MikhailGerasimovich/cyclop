#!/bin/bash
# Ставит markitdown[all] в отдельное окружение, из которого его зовёт вкладка
# «Markdown».
#
#   Tools/markitdown/install.sh                       — с PyPI
#   Tools/markitdown/install.sh ../markitdown         — из локального клона
#
# Окружение живёт в ~/Library/Application Support/Cyclop/MarkItDown, а не в
# бандле: markitdown со всеми форматами — это pandas, onnxruntime, pdfminer и
# ещё полсотни пакетов, сотни мегабайт против трёх мегабайт самого Cyclop.
# Поставить их нужно один раз, и только тому, кто этой вкладкой пользуется.
#
# Этот же скрипт лежит в бандле и запускается кнопкой «Установить» в панели —
# поэтому он не рассчитывает на PATH из терминала и ищет uv и питон сам.
set -euo pipefail

VERSION="0.1.8"
HOME_DIR="${CYCLOP_MARKITDOWN_HOME:-$HOME/Library/Application Support/Cyclop/MarkItDown}"
VENV="$HOME_DIR/venv"
MARKER="$VENV/.cyclop-installed"
SOURCE="${1:-}"

# У приложения, запущенного из Finder, PATH — /usr/bin:/bin:/usr/sbin:/sbin.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

if [ -n "$SOURCE" ]; then
    # Клон целиком или сразу packages/markitdown — подходит и то и другое.
    [ -d "$SOURCE/packages/markitdown" ] && SOURCE="$SOURCE/packages/markitdown"
    SOURCE="$(cd "$SOURCE" && pwd)"
    [ -f "$SOURCE/pyproject.toml" ] || { echo "!!! в $SOURCE нет pyproject.toml" >&2; exit 1; }
    REQUIREMENT="markitdown[all] @ file://$SOURCE"
else
    REQUIREMENT="markitdown[all]==$VERSION"
fi

mkdir -p "$HOME_DIR"
# Метка снимается первой: окружение, которое начали ставить и не доставили,
# не должно считаться готовым.
rm -f "$MARKER"

if command -v uv >/dev/null 2>&1; then
    echo "==> uv: окружение в $VENV"
    # 3.13, а не самый свежий: под ним точно есть колёса onnxruntime, на
    # котором magika узнаёт тип файла. Если такого питона нет, uv скачает его
    # сам, в свой кеш.
    uv venv --quiet --allow-existing --python 3.13 "$VENV"
    echo "==> uv: $REQUIREMENT"
    uv pip install --quiet --python "$VENV/bin/python" "$REQUIREMENT"
else
    # Без uv — обычный venv. Системный /usr/bin/python3 тут не годится:
    # это 3.9, а markitdown просит 3.10 и новее.
    PYTHON=""
    for candidate in python3.13 python3.12 python3.11 python3.10; do
        if command -v "$candidate" >/dev/null 2>&1; then PYTHON="$(command -v "$candidate")"; break; fi
    done
    if [ -z "$PYTHON" ]; then
        echo "!!! нужен uv (brew install uv) или Python 3.10–3.13" >&2
        exit 1
    fi
    echo "==> $PYTHON -m venv $VENV"
    "$PYTHON" -m venv "$VENV"
    "$VENV/bin/python" -m pip install --quiet --upgrade pip
    echo "==> pip: $REQUIREMENT"
    "$VENV/bin/python" -m pip install --quiet "$REQUIREMENT"
fi

"$VENV/bin/python" -I -c "import markitdown; print('==> markitdown', markitdown.__version__)"

# Не обязательны, но без них часть форматов беднее: exiftool даёт метаданные
# картинок и аудио, ffmpeg нужен, чтобы расшифровать mp3 и m4a.
for tool in exiftool ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || echo "    нет $tool — поставьте: brew install $tool"
done

touch "$MARKER"
echo "==> готово"
