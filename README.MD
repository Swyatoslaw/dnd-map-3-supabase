# dnd-map-3-supabase

Схема базы данных и Storage-конфигурация для Online Game Board.

Project ID: `focupfjcilraamzwfsuf`

## Как применить схему

Пока нет Supabase CLI / access token, миграции применяются вручную, **по порядку номеров**:

1. Открыть [SQL Editor](https://supabase.com/dashboard/project/focupfjcilraamzwfsuf/sql/new) проекта.
2. Скопировать содержимое [`supabase/migrations/0001_init.sql`](supabase/migrations/0001_init.sql) целиком, выполнить (Run).
3. Затем то же самое с [`supabase/migrations/0002_players_replica_identity.sql`](supabase/migrations/0002_players_replica_identity.sql) — без неё удаление игрока (`delete_player`) не долетает до других участников через Realtime (см. комментарий в файле).
4. Затем [`supabase/migrations/0003_get_player_tokens.sql`](supabase/migrations/0003_get_player_tokens.sql) — добавляет RPC для получения `player_token` (нужно владельцу, чтобы копировать ссылки-приглашения).
5. Затем [`supabase/migrations/0004_player_self_edit.sql`](supabase/migrations/0004_player_self_edit.sql) — добавляет `rooms.allow_player_edit` и меняет сигнатуру `edit_player` (теперь принимает ещё и `player_token`, чтобы игрок мог редактировать себя, когда владелец это разрешил).
6. Затем [`supabase/migrations/0005_app_settings.sql`](supabase/migrations/0005_app_settings.sql) — добавляет таблицу `app_settings` (одна строка, `id=1`) с флагом `disable_room_creation`.

Проверить результат:
- Table Editor → должны появиться `rooms`, `players`, `room_secrets`, `player_secrets`, `app_settings`.
- Database → Replication → `supabase_realtime` должна содержать `rooms` и `players`.
- Storage → должны появиться бакеты `maps` и `avatars` (публичные).

Если позже поставите Supabase CLI и сделаете `supabase link`, эту же папку `supabase/migrations` можно применять через `supabase db push`.

## Модель безопасности

Регистрации/аккаунтов нет. Доступ определяется двумя типами непредсказуемых UUID-токенов:

- `owner_token` — даёт право управлять комнатой (только ведущий).
- `player_token` — даёт право двигать одну конкретную фишку.

Токены хранятся в отдельных таблицах `room_secrets` / `player_secrets`, у которых нет RLS-политик для `anon` — их нельзя прочитать напрямую через API, только сравнить внутри RPC-функций. Таблицы `rooms` и `players` секретов не содержат и открыты на чтение всем (в т.ч. через Realtime).

**Все изменения идут только через RPC-функции** (`supabase.rpc(...)` на фронтенде), прямые `insert`/`update`/`delete` в таблицы для анонимной роли запрещены.

## RPC-контракт (для фронтенда)

| Функция | Аргументы | Возвращает | Кто может вызвать |
|---|---|---|---|
| `create_room()` | — | `{ room_id, owner_token }` | любой (создание новой комнаты); бросает `room_creation_disabled`, если `app_settings.disable_room_creation = true` |
| `verify_owner(room_id, owner_token)` | | `boolean` | любой — для проверки валидности admin-ссылки |
| `update_room_map(room_id, owner_token, background_url)` | | `void` | владелец |
| `create_player(room_id, owner_token, name, avatar_url?)` | | `{ player_id, player_token }` | владелец |
| `edit_player(player_id, name?, avatar_url?, owner_token?, player_token?)` | | `void` | владелец (любой игрок) или сам игрок (только своя запись, только если `rooms.allow_player_edit = true`) |
| `delete_player(player_id, owner_token)` | | `void` | владелец |
| `get_player_id_for_token(room_id, player_token)` | | `uuid \| null` | любой — игрок узнаёт, какая фишка его |
| `move_token(player_id, x, y, owner_token?, player_token?)` | `x`/`y` в процентах 0..100 | `void` | владелец (любая фишка) или игрок (только своя) |
| `get_player_tokens(room_id, owner_token)` | | `{ player_id, player_token }[]` | владелец — для построения/копирования ссылок-приглашений |
| `set_player_edit_allowed(room_id, owner_token, allowed)` | | `void` | владелец — включает/выключает возможность игроков редактировать себя |

Картинки (карта, аватары) заливаются напрямую в Storage (`maps/`, `avatars/`) через клиент, в таблицы попадает только публичный URL.

## Глобальные настройки (`app_settings`)

Единственная строка (`id = 1`), которая никогда не редактируется через приложение — только вручную, через Table Editor или SQL Editor в дашборде Supabase:

```sql
update public.app_settings set disable_room_creation = true where id = 1;
```

Сейчас один флаг — `disable_room_creation` (по умолчанию `false`). Пока он `true`, `create_room()` бросает ошибку `room_creation_disabled`, и фронтенд показывает кнопку «Создать комнату» задизейбленной с пояснением. Это проверяется на сервере внутри самой RPC-функции, а не только в интерфейсе — прямой вызов RPC в обход UI тоже будет отклонён.
