"""Мост между Cyclop и markitdown.

Cyclop запускает этот файл питоном из окружения, которое поставил install.sh:

    python -I bridge.py --language ru-RU <путь к файлу или ссылка>

и ждёт на stdout ровно один JSON:

    {"title": "...", "markdown": "..."}   — получилось, код выхода 0
    {"error": "..."}                      — не получилось, код выхода 1

Почему не CLI самого markitdown. Он печатает markdown в stdout как есть, а
ошибку — туда же, обычным текстом, с трассировками всех конвертеров подряд.
Отличить одно от другого Cyclop смог бы только по коду выхода, а показать в
панели — только всю простыню. Здесь же ошибка сведена к одной фразе, а заголовок
документа (у ссылки — заголовок страницы или видео) приходит отдельно и идёт в
имя файла.
"""

import argparse
import contextlib
import json
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", help="путь к файлу или http(s)-ссылка")
    parser.add_argument(
        "--language",
        default="en-US",
        help="язык речи для расшифровки аудио, например ru-RU",
    )
    args = parser.parse_args()

    # stdout — канал для одного JSON, и ничего другого в нём быть не должно.
    # Библиотеки внутри markitdown иногда печатают туда сами (предупреждения,
    # прогресс), поэтому на время работы всё это уходит в stderr.
    out = sys.stdout.buffer
    try:
        with contextlib.redirect_stdout(sys.stderr):
            result = convert(args.source, args.language)
    except Exception as error:  # noqa: BLE001 — любая ошибка идёт в панель
        out.write(encode({"error": describe(error)}))
        return 1

    out.write(encode({"title": result.title, "markdown": result.markdown}))
    return 0


def convert(source: str, language: str):
    import requests
    from markitdown import MarkItDown

    # С «python-requests/x.y» в User-Agent часть сайтов отвечает 403 —
    # Википедия первой. Заголовок Accept — тот же, что markitdown ставит
    # своей сессии сам: сайт, умеющий отдавать markdown, отдаст его сразу.
    session = requests.Session()
    session.headers.update(
        {
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
            ),
            "Accept": "text/markdown, text/html;q=0.9, text/plain;q=0.8, */*;q=0.1",
        }
    )

    # Плагины выключены: OCR-плагин без LLM-ключа всё равно ничего не делает,
    # а распознавание текста на картинках Cyclop делает сам, через Vision.
    md = MarkItDown(enable_plugins=False, requests_session=session)
    return md.convert(source.strip(), language=language)


def describe(error: Exception) -> str:
    """Одна-две строки вместо трассировки.

    FileConversionException перечисляет все попытки разом, и полезное в нём —
    сообщения исключений, а не имена конвертеров вокруг них.
    """
    from markitdown import FileConversionException

    if isinstance(error, FileConversionException) and error.attempts:
        reasons = []
        for attempt in error.attempts:
            if attempt.exc_info is None:
                continue
            reason = first_line(attempt.exc_info[1]) or attempt.exc_info[0].__name__
            if reason not in reasons:
                reasons.append(reason)
        if reasons:
            return "\n".join(reasons)
    return first_line(error) or type(error).__name__


def first_line(error: BaseException) -> str:
    text = str(error).strip()
    return text.splitlines()[0].strip() if text else ""


def encode(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False).encode("utf-8")


if __name__ == "__main__":
    sys.exit(main())
