"""
Сервер обязан подхватывать ключи из .env — иначе заполненный .env молча
игнорируется и провайдер падает с «deepseek_api_key не задан».

Проверяем обещанный в .env.example приоритет:
    реальное окружение (systemd/shell) > .env > config.json > дефолты

Запуск:  python server/tests/test_env_loading.py
"""

import os
import sys
import shutil
import tempfile

TESTS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(TESTS, "..")))

TMP = tempfile.mkdtemp(prefix="env-load-test-")
os.environ["USAGE_DB"] = os.path.join(TMP, "usage.db")
os.environ["USAGE_TXT"] = os.path.join(TMP, "token_usage.txt")

import server  # noqa: E402


def write_env(name, body):
    path = os.path.join(TMP, name)
    with open(path, "w", encoding="utf-8") as f:
        f.write(body)
    return path


def main():
    failed = 0

    # 1. Ключ из .env попадает в окружение и доезжает до CONFIG.
    env = write_env(".env", "DEEPSEEK_API_KEY=sk-from-dotenv\n")
    os.environ.pop("DEEPSEEK_API_KEY", None)
    server.load_env_files([env])
    if os.environ.get("DEEPSEEK_API_KEY") != "sk-from-dotenv":
        print("FAIL: .env не загружен в os.environ")
        failed += 1
    if server.load_config().get("deepseek_api_key") != "sk-from-dotenv":
        print("FAIL: load_config() не подхватил ключ из .env")
        failed += 1

    # 2. Реальное окружение важнее .env — .env не должен затирать systemd/shell.
    os.environ["DEEPSEEK_API_KEY"] = "sk-from-shell"
    server.load_env_files([env])
    if os.environ.get("DEEPSEEK_API_KEY") != "sk-from-shell":
        print("FAIL: .env затёр переменную из реального окружения")
        failed += 1

    # 3. Первый файл в списке важнее последующих (server/.env > корневой .env).
    root = write_env("root.env", "AQBOBEK_MAIN_TOKEN=root\n")
    local = write_env("local.env", "AQBOBEK_MAIN_TOKEN=local\n")
    os.environ.pop("AQBOBEK_MAIN_TOKEN", None)
    server.load_env_files([local, root])
    if os.environ.get("AQBOBEK_MAIN_TOKEN") != "local":
        print("FAIL: приоритет файлов нарушен — корневой .env перебил server/.env")
        failed += 1

    # 4. Отсутствующий файл — не ошибка.
    try:
        server.load_env_files([os.path.join(TMP, "нет-такого.env")])
    except Exception as e:
        print("FAIL: отсутствующий .env уронил загрузку:", e)
        failed += 1

    shutil.rmtree(TMP, ignore_errors=True)
    print("FAILED" if failed else "OK")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
