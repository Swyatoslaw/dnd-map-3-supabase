# dnd-map-3-supabase

Схема базы данных и Storage-конфигурация для Online Game Board.

Project ID: `focupfjcilraamzwfsuf`

## Как применить схему

Пока нет Supabase CLI / access token, миграция применяется вручную:

1. Открыть [SQL Editor](https://supabase.com/dashboard/project/focupfjcilraamzwfsuf/sql/new) проекта.
2. Скопировать содержимое [`supabase/migrations/0001_init.sql`](supabase/migrations/0001_init.sql) целиком.
3. Выполнить (Run).

Проверить результат:
- Table Editor → должны появиться `rooms`, `players`, `room_secrets`, `player_secrets`.
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
| `create_room()` | — | `{ room_id, owner_token }` | любой (создание новой комнаты) |
| `verify_owner(room_id, owner_token)` | | `boolean` | любой — для проверки валидности admin-ссылки |
| `update_room_map(room_id, owner_token, background_url)` | | `void` | владелец |
| `create_player(room_id, owner_token, name, avatar_url?)` | | `{ player_id, player_token }` | владелец |
| `edit_player(player_id, owner_token, name?, avatar_url?)` | | `void` | владелец |
| `delete_player(player_id, owner_token)` | | `void` | владелец |
| `get_player_id_for_token(room_id, player_token)` | | `uuid \| null` | любой — игрок узнаёт, какая фишка его |
| `move_token(player_id, x, y, owner_token?, player_token?)` | `x`/`y` в процентах 0..100 | `void` | владелец (любая фишка) или игрок (только своя) |

Картинки (карта, аватары) заливаются напрямую в Storage (`maps/`, `avatars/`) через клиент, в таблицы попадает только публичный URL.
