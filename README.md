# KESHNYA Plugins

Личный маркетплейс плагинов для Claude.

## Структура

```
.claude-plugin/marketplace.json   — каталог маркетплейса
plugins/<имя-плагина>/            — папка каждого плагина
  .claude-plugin/plugin.json      — описание плагина
  skills/, commands/, agents/     — содержимое
```

## Подключение

```
/plugin marketplace add keshnyaaa/keshnya-plugins
```

## Добавить плагин

1. Создать папку `plugins/<имя>/` с `.claude-plugin/plugin.json`.
2. Добавить запись в `plugins` в `.claude-plugin/marketplace.json`:

```json
{ "name": "<имя>", "source": "./plugins/<имя>", "description": "..." }
```
