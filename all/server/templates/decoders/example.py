"""Пример-декодер (база). Возвращает готовый план шагов для расширения."""


def decode(data=None):
    return {
        "template": "example-base",
        "steps": [
            {
                "selector": "#some-button",
                "method": "click",
                "address": "https://herachxx.github.io/damumed-example/",
            },
            {
                "selector": "#tab-visit",
                "method": "click",
                "navigates": True,
                "address": "https://herachxx.github.io/damumed-example/",
            },
        ],
    }


if __name__ == "__main__":
    import json

    print(json.dumps(decode(), ensure_ascii=False, indent=2))
