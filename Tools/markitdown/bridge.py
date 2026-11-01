"""Мост между Cyclop и markitdown.

Cyclop запускает этот файл питоном из окружения, которое поставил install.sh:

    python -I bridge.py --language ru-RU <путь к файлу или ссылка>
    python -I bridge.py --list-models

и ждёт на stdout ровно один JSON:

    {"title": "...", "markdown": "...", "usage": {...}, "warnings": [{...}]}
    {"error": "...", "usage": {...}}                     — код выхода 1
    {"models": ["..."]}                                  — для --list-models

Почему не CLI самого markitdown. Он печатает markdown в stdout как есть, а
ошибку — туда же, обычным текстом, с трассировками всех конвертеров подряд.
Здесь же ошибка сведена к одной фразе, заголовок документа (у ссылки —
заголовок страницы или видео) приходит отдельно и идёт в имя файла, а расход
токенов — отдельным полем.

ИИ. Включается переменными окружения, которые Cyclop выставляет, только если
обработка через ИИ включена в настройках:

    CYCLOP_LLM_KIND      anthropic | openai
    CYCLOP_LLM_BASE_URL  адрес API; пусто — адрес провайдера по умолчанию
    CYCLOP_LLM_MODEL     модель
    CYCLOP_LLM_API_KEY   ключ; у локальных моделей может быть пустым

Ключ идёт через окружение, а не аргументом: аргументы любого процесса видны
всем пользователям машины через ps.

markitdown зовёт модель в двух местах — описание картинок и, через плагин
markitdown-ocr, распознавание текста на картинках внутри PDF, Word, PowerPoint
и Excel. Оба зовут клиента одинаково: client.chat.completions.create(model=,
messages=) в форме OpenAI. MeteredClient ниже притворяется таким клиентом и
передаёт запрос настоящему SDK — anthropic для Claude, openai для всех
остальных (OpenAI, Gemini, OpenRouter, Ollama, LM Studio: у всех API в форме
OpenAI). По дороге он считает токены, уменьшает картинки и не даёт одной
неверной настройке превратиться в сотню одинаково упавших запросов.
"""

import argparse
import base64
import contextlib
import io
import json
import os
import sys
from types import SimpleNamespace

# Длинная сторона картинки, отправляемой модели. Токены картинки растут с её
# площадью, а страница скана в 300 DPI — это 2550×3300: втрое больше токенов,
# чем нужно, чтобы прочитать на ней текст.
MAX_IMAGE_SIDE = 2000

# Форматы, которые принимают и Claude, и API в форме OpenAI. Остальное
# (TIFF, BMP — частые гости в документах Office) перекодируется в PNG.
SUPPORTED_MIME = {"image/png", "image/jpeg", "image/gif", "image/webp"}

# Подсказка markitdown для описания картинок — на английском, и ответ приходит
# на английском. Её одну дополняет языком пользователя: промпт для
# распознавания текста не трогается, текст должен остаться на своём языке.
CAPTION_PROMPT = "Write a detailed caption for this image."
LANGUAGE_NAMES = {
    "ru": "Russian", "en": "English", "uk": "Ukrainian", "be": "Belarusian",
    "kk": "Kazakh", "de": "German", "fr": "French", "es": "Spanish",
    "it": "Italian", "pt": "Portuguese", "pl": "Polish", "tr": "Turkish",
    "zh": "Chinese", "ja": "Japanese", "ko": "Korean",
}

# Модели Claude, которые умеют server-side fallback: при отказе по политике
# API сам повторяет запрос на запасной модели, внутри того же вызова.
FALLBACK_MODELS = {"claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"}
ANTHROPIC_API = "https://api.anthropic.com"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", nargs="?", help="путь к файлу или http(s)-ссылка")
    parser.add_argument(
        "--language",
        default="en-US",
        help="язык пользователя: речь в аудио и подписи к картинкам",
    )
    parser.add_argument(
        "--list-models", action="store_true", help="список моделей провайдера"
    )
    args = parser.parse_args()

    # stdout — канал для одного JSON, и ничего другого в нём быть не должно.
    # Библиотеки внутри markitdown иногда печатают туда сами (предупреждения,
    # прогресс), поэтому на время работы всё это уходит в stderr.
    out = sys.stdout.buffer
    meter = Meter()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            if args.list_models:
                payload = {"models": list_models()}
            elif args.source:
                result = convert(args.source, args.language, meter)
                payload = {"title": result.title, "markdown": result.markdown}
            else:
                parser.error("нужен путь, ссылка или --list-models")
    except Exception as error:  # noqa: BLE001 — любая ошибка идёт в панель
        out.write(encode(meter.attach({"error": describe(error)})))
        return 1

    out.write(encode(meter.attach(payload)))
    return 0


def convert(source: str, language: str, meter: "Meter"):
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

    options = {"requests_session": session}
    backend = make_backend(meter)
    if backend is not None:
        # Плагины — это markitdown-ocr: он читает текст на картинках внутри
        # PDF, Word, PowerPoint и Excel. Без модели он молчит, поэтому
        # включается только вместе с ней. Распознавание отдельных картинок и
        # сканов без ИИ Cyclop делает сам, через Vision.
        options.update(
            enable_plugins=True,
            llm_client=MeteredClient(backend, language),
            llm_model=backend.model,
        )
    md = MarkItDown(**options)
    return md.convert(source.strip(), language=language)


def list_models() -> list:
    backend = make_backend(Meter(), require_model=False)
    if backend is None:
        raise RuntimeError("AI is not configured")
    return backend.list_models()


# MARK: - Учёт


class Meter:
    """Расход токенов за один запуск и то, что пошло не так по дороге."""

    def __init__(self):
        self.requests = 0
        self.input_tokens = 0
        self.output_tokens = 0
        self.warnings = []

    def add(self, input_tokens, output_tokens):
        self.requests += 1
        self.input_tokens += input_tokens or 0
        self.output_tokens += output_tokens or 0

    def warn(self, code: str, detail: str = ""):
        """Код, а не фраза: текст предупреждения Cyclop берёт из своих
        таблиц строк, на языке панели. detail — то, что перевести нельзя:
        имя модели, адрес, сообщение сервера."""
        warning = {"code": code, "detail": detail}
        if warning not in self.warnings:
            self.warnings.append(warning)

    def attach(self, payload: dict) -> dict:
        # Нет вызовов — нет и поля: Cyclop показывает расход только у тех
        # конвертаций, которые на самом деле ходили к модели.
        if self.requests:
            payload["usage"] = {
                "requests": self.requests,
                "input_tokens": self.input_tokens,
                "output_tokens": self.output_tokens,
            }
        if self.warnings:
            payload["warnings"] = self.warnings
        return payload


# MARK: - Клиент для markitdown


class MeteredClient:
    """То, что markitdown считает клиентом OpenAI."""

    def __init__(self, backend, language: str):
        self._backend = backend
        self._language = LANGUAGE_NAMES.get(language.split("-")[0].lower())
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self._create))

    def _create(self, *, model, messages, **_):
        prompt, images = split_message(messages)
        images = [image for image in (normalize(*pair) for pair in images) if image]
        text = ""
        # Картинка, которую не удалось ни открыть, ни перекодировать (WMF и
        # EMF из старых документов Office), стоит запроса без картинки —
        # то есть токенов за ответ ни о чём.
        if images:
            if prompt.strip() == CAPTION_PROMPT and self._language:
                prompt = f"{CAPTION_PROMPT} Write it in {self._language}."
            text = self._backend.complete(model, prompt, images)
        message = SimpleNamespace(content=text, role="assistant")
        return SimpleNamespace(choices=[SimpleNamespace(message=message)])


def split_message(messages):
    """Текст и картинки (mime, байты) из сообщения в форме OpenAI."""
    prompt, images = [], []
    for message in messages:
        content = message.get("content")
        if isinstance(content, str):
            prompt.append(content)
            continue
        for part in content or []:
            if part.get("type") == "text":
                prompt.append(part.get("text", ""))
            elif part.get("type") == "image_url":
                url = (part.get("image_url") or {}).get("url", "")
                header, _, data = url.partition(",")
                if header.startswith("data:") and ";base64" in header:
                    mime = header[5:].split(";")[0] or "application/octet-stream"
                    images.append((mime, base64.b64decode(data)))
    return "\n".join(prompt), images


def normalize(mime: str, data: bytes):
    """(mime, base64) в формате и размере, которые модель примет."""
    try:
        from PIL import Image
    except ImportError:
        return (mime, base64.b64encode(data).decode()) if mime in SUPPORTED_MIME else None

    try:
        image = Image.open(io.BytesIO(data))
        image.load()
    except Exception:  # noqa: BLE001 — формат, который Pillow не читает
        return None

    if mime in SUPPORTED_MIME and max(image.size) <= MAX_IMAGE_SIDE:
        return mime, base64.b64encode(data).decode()

    image.thumbnail((MAX_IMAGE_SIDE, MAX_IMAGE_SIDE))
    buffer = io.BytesIO()
    if image.mode in ("RGBA", "LA", "P"):
        image.save(buffer, format="PNG", optimize=True)
        mime = "image/png"
    else:
        image.convert("RGB").save(buffer, format="JPEG", quality=90)
        mime = "image/jpeg"
    return mime, base64.b64encode(buffer.getvalue()).decode()


# MARK: - Провайдеры


def make_backend(meter: Meter, require_model: bool = True):
    kind = os.environ.get("CYCLOP_LLM_KIND", "").strip()
    model = os.environ.get("CYCLOP_LLM_MODEL", "").strip()
    base_url = os.environ.get("CYCLOP_LLM_BASE_URL", "").strip() or None
    api_key = os.environ.get("CYCLOP_LLM_API_KEY", "").strip()
    if not kind or (require_model and not model):
        return None
    if kind == "anthropic":
        return AnthropicBackend(model, base_url, api_key, meter)
    return OpenAIBackend(model, base_url, api_key, meter)


class Backend:
    """Общее у провайдеров: учёт и остановка после неустранимой ошибки."""

    def __init__(self, model, meter: Meter):
        self.model = model
        self.meter = meter
        self.broken = False

    def complete(self, model, prompt, images) -> str:
        # Неверный ключ или несуществующая модель не исправятся к следующей
        # картинке. Документ на сто картинок без этой заглушки — сто
        # одинаковых отказов подряд и минута ожидания.
        if self.broken:
            return ""
        try:
            return self._complete(model, prompt, images)
        except Exception as error:  # noqa: BLE001
            fatal, code, detail = self._classify(error)
            if fatal:
                self.broken = True
            self.meter.warn(code, detail)
            return ""

    def _classify(self, error):
        """(остановиться ли, код, подробность) для ошибки SDK.

        У anthropic и openai одинаковые имена классов ошибок, поэтому разбор
        один на двоих: модуль SDK лежит в self._sdk."""
        sdk = self._sdk
        if isinstance(error, sdk.AuthenticationError):
            return True, "auth", ""
        if isinstance(error, sdk.PermissionDeniedError):
            return True, "permission", self.model
        if isinstance(error, sdk.NotFoundError):
            return True, "model", self.model
        if isinstance(error, sdk.RateLimitError):
            return False, "rate", ""
        if isinstance(error, sdk.APIStatusError):
            return error.status_code < 500, "status", f"{error.status_code}: {first_line(error)}"
        if isinstance(error, sdk.APIConnectionError):
            return True, "connection", self._base_url
        return False, "other", first_line(error) or type(error).__name__


class AnthropicBackend(Backend):
    def __init__(self, model, base_url, api_key, meter):
        super().__init__(model, meter)
        import anthropic

        self._sdk = anthropic
        self._base_url = base_url or ANTHROPIC_API
        self._client = anthropic.Anthropic(
            api_key=api_key or None, base_url=self._base_url, timeout=300.0, max_retries=2
        )

    def _complete(self, model, prompt, images) -> str:
        # Картинки — перед текстом: так их лучше всего понимает Claude.
        content = [
            {"type": "image", "source": {"type": "base64", "media_type": mime, "data": data}}
            for mime, data in images
        ]
        content.append({"type": "text", "text": prompt})
        request = dict(
            model=model,
            max_tokens=16000,
            messages=[{"role": "user", "content": content}],
        )
        official = self._base_url.rstrip("/") == ANTHROPIC_API
        if model in FALLBACK_MODELS and official:
            response = self._client.beta.messages.create(
                betas=["server-side-fallback-2026-07-01"], fallbacks="default", **request
            )
        else:
            response = self._client.messages.create(**request)

        usage = response.usage
        self.meter.add(
            (usage.input_tokens or 0)
            + (getattr(usage, "cache_creation_input_tokens", 0) or 0)
            + (getattr(usage, "cache_read_input_tokens", 0) or 0),
            usage.output_tokens,
        )
        if response.stop_reason == "refusal":
            self.meter.warn("refusal", self.model)
            return ""
        return "".join(block.text for block in response.content if block.type == "text")

    def list_models(self) -> list:
        models = []
        for model in self._client.models.list():
            # Только те, что видят картинки: другие здесь бесполезны. Прокси
            # и старые API могут не отдавать capabilities — тогда берём всё.
            if sees_images(model) is False:
                continue
            models.append(model.id)
        return models



def sees_images(model):
    """True, False или None — если сервер о картинках ничего не сказал.

    В SDK capabilities — типизированный объект, а в сыром JSON — словарь;
    разбираются оба, чтобы смена версии SDK не открыла список всем моделям."""
    capabilities = getattr(model, "capabilities", None)
    image_input = getattr(capabilities, "image_input", None)
    if image_input is None and isinstance(capabilities, dict):
        image_input = capabilities.get("image_input")
    if isinstance(image_input, dict):
        return image_input.get("supported")
    return getattr(image_input, "supported", None)


class OpenAIBackend(Backend):
    def __init__(self, model, base_url, api_key, meter):
        super().__init__(model, meter)
        import openai

        self._sdk = openai
        self._base_url = base_url or "https://api.openai.com/v1"
        # Локальным серверам ключ не нужен, а SDK без него не создаётся.
        self._client = openai.OpenAI(
            api_key=api_key or "not-needed", base_url=self._base_url, timeout=300.0, max_retries=2
        )

    def _complete(self, model, prompt, images) -> str:
        content = [{"type": "text", "text": prompt}]
        content += [
            {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}}
            for mime, data in images
        ]
        response = self._client.chat.completions.create(
            model=model, messages=[{"role": "user", "content": content}]
        )
        # Не каждый сервер в форме OpenAI отдаёт usage. Запрос всё равно
        # считается — нулевым расходом, но считается.
        usage = getattr(response, "usage", None)
        self.meter.add(
            getattr(usage, "prompt_tokens", 0) if usage else 0,
            getattr(usage, "completion_tokens", 0) if usage else 0,
        )
        choice = response.choices[0] if response.choices else None
        return (choice.message.content or "") if choice else ""

    def list_models(self) -> list:
        return sorted(model.id for model in self._client.models.list())



# MARK: - Ошибки и вывод


def describe(error: Exception) -> str:
    """Одна-две строки вместо трассировки.

    FileConversionException перечисляет все попытки разом, и полезное в нём —
    сообщения исключений, а не имена конвертеров вокруг них.
    """
    try:
        from markitdown import FileConversionException
    except ImportError:
        FileConversionException = ()  # noqa: N806

    if FileConversionException and isinstance(error, FileConversionException) and error.attempts:
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
