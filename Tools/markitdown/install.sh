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
OCR_VERSION="0.1.1"
# Версия самого окружения, а не markitdown: Cyclop сверяет её с той, что ему
# нужна, и предлагает обновить окружение, если оно старше. 2 — добавлены SDK
# провайдеров и плагин markitdown-ocr для обработки через ИИ.
ENVIRONMENT=2
HOME_DIR="${CYCLOP_MARKITDOWN_HOME:-$HOME/Library/Application Support/Cyclop/MarkItDown}"
VENV="$HOME_DIR/venv"
MARKER="$VENV/.cyclop-installed"
SOURCE="${1:-}"

# У приложения, запущенного из Finder, PATH — /usr/bin:/bin:/usr/sbin:/sbin.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

if [ -n "$SOURCE" ]; then
    # Клон целиком или его папка packages — подходит и то и другое: оба
    # пакета, markitdown и markitdown-ocr, лежат в packages рядом.
    [ -d "$SOURCE/packages" ] && SOURCE="$SOURCE/packages"
    SOURCE="$(cd "$SOURCE" && pwd)"
    [ -f "$SOURCE/markitdown/pyproject.toml" ] || { echo "!!! в $SOURCE нет markitdown/pyproject.toml" >&2; exit 1; }
    REQUIREMENTS=(
        "markitdown[all] @ file://$SOURCE/markitdown"
        "markitdown-ocr @ file://$SOURCE/markitdown-ocr"
    )
else
    REQUIREMENTS=("markitdown[all]==$VERSION" "markitdown-ocr==$OCR_VERSION")
fi
# SDK провайдеров для обработки через ИИ: anthropic — для Claude, openai —
# для всех API в форме OpenAI, локальные Ollama и LM Studio в том числе.
# Pillow приводит картинки к формату и размеру, которые модели принимают.
REQUIREMENTS+=("anthropic" "openai" "Pillow")

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
    echo "==> uv: ${REQUIREMENTS[*]}"
    uv pip install --quiet --python "$VENV/bin/python" "${REQUIREMENTS[@]}"
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
    echo "==> pip: ${REQUIREMENTS[*]}"
    "$VENV/bin/python" -m pip install --quiet "${REQUIREMENTS[@]}"
fi

"$VENV/bin/python" -I -c "import markitdown, markitdown_ocr, anthropic, openai; print('==> markitdown', markitdown.__version__, '· anthropic', anthropic.__version__, '· openai', openai.__version__)"

# Не обязательны, но без них часть форматов беднее: exiftool даёт метаданные
# картинок и аудио, ffmpeg нужен, чтобы расшифровать mp3 и m4a.
for tool in exiftool ffmpeg; do
    command -v "$tool" >/dev/null 2>&1 || echo "    нет $tool — поставьте: brew install $tool"
done

echo "$ENVIRONMENT" > "$MARKER"
echo "==> готово"
