"""
call_llm должен прокидывать endpoint конкретному провайдеру, иначе журнал
вызовов не покажет, откуда пришёл запрос — из /command или из /ocr-template.

Запуск:  python vox_server/tests/test_call_llm.py
"""

import os
import sys
import shutil
import asyncio
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="call-llm-test-")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

import vox_server as server  # noqa: E402

seen = {}


async def fake_openai(system, user, endpoint=None):
    seen["openai"] = endpoint
    return "{}"


async def fake_deepseek(system, user, endpoint=None):
    seen["deepseek"] = endpoint
    return "{}"


def main():
    server._call_openai = fake_openai
    server._call_deepseek = fake_deepseek

    failed = 0
    try:
        asyncio.run(server.call_llm("s", "u", "openai", endpoint="command"))
        asyncio.run(server.call_llm("s", "u", "deepseek", endpoint="ocr-template"))

        if seen.get("openai") != "command":
            failed += 1
            print("  FAIL openai: ожидали 'command', получили " + repr(seen.get("openai")))
        else:
            print("  OK   openai получает endpoint")

        if seen.get("deepseek") != "ocr-template":
            failed += 1
            print("  FAIL deepseek: ожидали 'ocr-template', получили " + repr(seen.get("deepseek")))
        else:
            print("  OK   deepseek получает endpoint")
    except Exception as e:
        failed += 1
        print("  ERR  " + type(e).__name__ + ": " + str(e))
    finally:
        shutil.rmtree(TMP, ignore_errors=True)

    print("\n{}/2 тестов прошло".format(2 - failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
