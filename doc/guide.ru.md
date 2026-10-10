# xref: индекс кода, которому можно верить

**Спецификация, а не изложение идеи.** Ниже всё, что нужно, чтобы собрать
инструмент и получить работающий результат без круга «не работает — чиним»:
полная схема хранения, контракты записей, рабочий код тех разборов, где ошибиться
легче всего, и список проверок, которыми результат удостоверяется.

Что получается: локальная база с фактами о коде и о средах плюс обёртка
`bin/xref` над набором задач. Ни демона, ни службы, ни внешнего сервиса.
Девятнадцать тысяч строк на одном языке — пятнадцать с половиной сам инструмент
и три с небольшим спеки, — из зависимостей только парсер SQL вашей базы. Полный
разбор дерева в 21,5 тысячи файлов — три минуты, догон после правки — доли
секунды.

Стек в примерах: Ruby/Rails + PostgreSQL. Приёмы от платформы не зависят; места,
где важна именно она, помечены. Код приведён рабочим, а не иллюстративным: он
взят из работающего инструмента и обезличен.

**Что именно проверено и чем это прогнать — `verification.ru.md`** рядом с этим
файлом: там результаты контрольных опытов по пунктам и честный список того, что
НЕ проверялось.

**Приведённое проверено исполнением, а не вычиткой.** Вся схема из части III и
все представления из части V накатываются на чистую базу без единой ошибки
(31 таблица, 65 представлений, каждое отвечает на `select`); все девятнадцать
фрагментов кода проходят проверку синтаксиса; программа разбора логов проверена
на образце и даёт оба счётчика. Если у вас что-то не накатилось — дело в версии базы, и об
этом стоит сказать, а не обходить.

**Числа в тексте — наблюдения с датой, а не свойства инструмента.** Они стареют:
дерево растёт, слои добавляются, доли ложных находок падают по мере проверок.
Ни одно число отсюда не годится в чужой отчёт без своего замера.

Писалось по опыту приложения в 600 тысяч строк, 8 тысяч файлов, двадцать лет
истории, запросы к базе строками, пять живых экземпляров базы со разъехавшимися
схемами. Если ваш проект моложе и весь на ORM — нужны слои 1–3, остальное по
потребности.

---

# Часть I. Зачем

Поиск по тексту и «найти использования» отвечают не на тот вопрос. Три причины,
каждая стоила инцидента.

**Имя — плохой ключ.** Короткое имя колонки одновременно оказывается именем
сервера в инфраструктуре и самым популярным именем локальной переменной. Поиск
даёт три сотни совпадений, из которых к базе относится шесть.

**Запрос живёт в строке, а не в коде.** Там, где SQL написан текстом, среда
разработки не знает, что строка трогает таблицу. Для неё это просто текст. А
дальше в этой строке стоит подстановка, и имя таблицы собирается на ходу.

**Среды разъехались, и из кода это не видно.** Если живых баз больше одной, рано
или поздно таблица окажется только в части из них. Код выглядит безупречно и
падает только там, где не хватает. Это худший класс ошибок: он молчит до боя.

---

# Часть II. Что получается

```sh
bin/xref where users.email    # где трогают таблицу или колонку: разобранным
                              #   запросом, через ORM, «похоже по тексту» — врозь
bin/xref column recover_      # в каких таблицах и средах живёт колонка
bin/xref blind                # код ходит в таблицу, которой в этой среде нет
bin/xref drift                # чем схемы сред отличаются друг от друга
bin/xref migrations           # какие миграции применены в каждой среде, чего не
                              #   хватает и чем среды разошлись
bin/xref env                  # ключи окружения: код читает, а в среде нет
                              #   (только ИМЕНА — значения не читаются никогда)
bin/xref texts                # тексты: ключ зовут, а перевода нет — и наоборот
bin/xref holes [имя]          # что подставляется в запрос интерполяцией,
                              #   в какое место запроса и откуда берётся текст
bin/xref calls [метод]        # кто зовёт: из кода, из шаблона, через send,
                              #   по символу, по роуту
bin/xref callers <файл>       # кто ссылается на файл и кто рисовал его в бою
bin/xref dead                 # неиспользуемое: роуты, действия, контроллеры,
                              #   методы (VIS=public — ещё и публичные)
bin/xref changed [ref]        # что задето правкой: методы, их вызывающие,
                              #   таблицы и среды, где этих таблиц нет
bin/xref scope "<задача>"     # от задачи к файлам: точки входа, карта, порядок
                              #   чтения, таблицы под угрозой, слепые места
bin/xref boundary <файл>      # что прочитать, прежде чем править этот файл
bin/xref rules                # архитектурные правила и их защёлки
bin/xref route /orders        # роуты и файлы контроллеров по образцу пути
bin/xref columns <таблица>    # по колонкам: что читается, что пишется, что мертво,
                              #   и что говорят живые данные
bin/xref fill <таблица>       # сплошной проход по данным: заполненность колонок,
                              #   умолчания, свежая когорта, сканирования индексов
bin/xref lineage <табл.кол>   # откуда берётся значение колонки
bin/xref components           # компонентная модель: роли, границы, циклы
bin/xref views                # какие шаблоны и действия работали в бою
bin/xref sql [дата]           # какие запросы ВЫПОЛНЯЛИСЬ: узоры из боевых логов,
                              #   разрешённые имена таблиц, колонки в условиях
bin/xref sql profile [дней]   # то же из статистики самой базы (pg_profile):
                              #   окно неделями, а не сутками (IV.15)
bin/xref css                  # стили: что объявлено, чем файл жив, какие классы
                              #   не поминает никто и есть ли правило В КОНТУРЕ
bin/xref js                   # javascript: связка шаблон→контроллер→метод,
                              #   функции верхнего уровня, вызовы библиотек
bin/xref docs                 # документы: битые ссылки, устаревшие пути, примеры
bin/xref front                # конфигурация фронта и опасные места в скриптах
bin/xref find "<образец>"     # поиск по тексту + что про находки знает индекс
bin/xref findings [разряд]    # находки по разрядам: сколько в отчётах, сколько
                              #   проверено, доля ЛОЖНЫХ в разряде (VI.3)
bin/xref verdict <разряд> <предмет> ложная|настоящая "почему" [чем]
                              # проверено у первоисточника — запомнить
bin/xref locale               # самопроверка кодировок: что видит ruby без локали
bin/xref audit                # аудит самого индекса: связность, шум, разрывы
bin/xref refresh              # обновить схемы, факты приложения, код
```

Команды сбора (`schema`, `app`, `code`, `json`, `places`) описаны в части IV —
снаружи их зовут редко, запросы сами догоняют индекс по изменившимся файлам.

Обёртка — меньше сотни строк на `sh`, которые зовут задачи сборщика
(`xref:schema`, `xref:code`, `xref:app`, …). Внутри задач — обычный SQL по базе
индекса.

---

# Часть III. Контракты

Три вещи, которые надо зафиксировать ДО написания кода. Если их не зафиксировать,
переписывать придётся всё.

## III.1. Схема хранения

Полностью. Это PostgreSQL; на другой базе поменяются только типы массивов и
`jsonb`.

```sql
-- Источники схем: среды, дамп из репозитория, колоночная база.
create table if not exists sources (
  id         serial primary key,
  name       text not null unique,
  kind       text not null,          -- 'pg' | 'hbase' | …: разводит пространства имён
  transport  text not null,          -- как снимать: activerecord | ssh_psql | structure_sql | thrift
  detail     jsonb not null default '{}'::jsonb
);

-- Снимок одного источника. Храним историю: видно, КОГДА колонка появилась.
create table if not exists snapshots (
  id             serial primary key,
  source_id      integer not null references sources(id) on delete cascade,
  taken_at       timestamptz not null default now(),
  git_sha        text,                -- на каком коде снимали
  server_version text,
  database_name  text,
  ok             boolean not null default true,
  error          text,                -- неудачный снимок тоже ряд: видно, что источник отвалился
  warnings       text[] not null default '{}',
  duration_ms    integer
);
create index if not exists idx_snapshots_source on snapshots (source_id, taken_at desc);

create table if not exists db_tables (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  name        text not null,
  kind        text not null,          -- r | p | v | m | f: таблица, секция, вьюха, матвьюха, сторонняя
  est_rows    bigint,
  primary key (snapshot_id, name)
);

create table if not exists db_columns (
  snapshot_id  integer not null references snapshots(id) on delete cascade,
  table_name   text not null,
  column_name  text not null,
  ordinal      integer not null,
  data_type    text not null,
  not_null     boolean not null default false,
  default_expr text,
  primary key (snapshot_id, table_name, column_name)
);
create index if not exists idx_db_columns_name on db_columns (column_name);

create table if not exists db_indexes (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  table_name  text not null,
  index_name  text not null,
  is_unique   boolean not null default false,
  is_primary  boolean not null default false,
  definition  text not null,
  primary key (snapshot_id, table_name, index_name)
);

-- В базе живёт не только структура, но и КОД: правила перезаписи, триггеры,
-- функции. Без них ответ «эту колонку никто не читает» бывает ложью: правило
-- `ON INSERT … DO INSTEAD UPDATE … SET x = x + new.x` читает колонку, которую
-- увеличивает. У нас таких колонок оказалось 165.
create table if not exists db_rules (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  table_name  text not null,
  rule_name   text not null,
  event       text not null,          -- insert | update | delete | select
  is_instead  boolean not null default false,
  definition  text not null,
  primary key (snapshot_id, table_name, rule_name)
);

create table if not exists db_triggers (
  snapshot_id   integer not null references snapshots(id) on delete cascade,
  table_name    text not null,
  trigger_name  text not null,
  function_name text,                 -- тело лежит в функции, её и разбираем
  definition    text not null,
  primary key (snapshot_id, table_name, trigger_name)
);

-- `identity` — имя с типами аргументов: у функций бывают перегрузки.
create table if not exists db_routines (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  identity    text not null,
  name        text not null,
  kind        text not null,          -- function | procedure | aggregate | window
  language    text not null,
  returns     text,
  body        text,
  primary key (snapshot_id, identity)
);

-- Ограничение — тоже потребитель колонки: тронуть её молча не даст база.
create table if not exists db_constraints (
  snapshot_id     integer not null references snapshots(id) on delete cascade,
  table_name      text not null,
  constraint_name text not null,
  kind            text not null,      -- p | f | u | c | x | n
  ref_table       text,
  columns         text,               -- имена из каталога, а не регуляркой по тексту
  definition      text not null,
  primary key (snapshot_id, table_name, constraint_name)
);

create table if not exists db_sequences (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  name        text not null,
  owned_by    text,
  primary key (snapshot_id, name)
);

-- Разобранные тела правил и функций. Отдельно от `code_refs`: это не файлы, а
-- объекты базы, и жизненный цикл у них снимочный. Подмешиваются в те же виды,
-- поэтому «колонку читает правило» встаёт рядом с «колонку читает код».
create table if not exists db_refs (
  snapshot_id integer not null references snapshots(id) on delete cascade,
  object      text not null,
  object_kind text not null,          -- rule | trigger | routine
  kind        text not null,          -- pg_table | pg_column | pg_column_write | col_lineage
  token       text not null,
  owner       text not null default '',
  detail      jsonb,
  primary key (snapshot_id, object, kind, token, owner)
);

-- Разбор кода. `sha` — ключ инкрементальности.
create table if not exists code_files (
  path       text primary key,
  sha        text not null,
  lang       text not null,           -- ruby | view | js | sql | other
  bytes      integer,
  refs_count integer not null default 0,
  git_sha    text,
  -- Отпечаток ВХОДОВ разбора: имена из схем, карта моделей, карта констант. Без
  -- него смена схемы не инвалидирует ничего — SHA файла тот же, а слой
  -- кандидатов и привязка колонок к моделям уже другие. Именно так индекс может
  -- месяц утверждать, что таблицы нет в двух средах.
  inputs_sha text,
  indexed_at timestamptz not null default now()
);

-- Главная таблица. Одна строка на (файл, вид записи, имя, владелец) — НЕ на
-- каждое вхождение: иначе популярное имя даст сотни тысяч строк и ровно столько
-- же пользы, сколько одна. Состав `detail` — в III.2.
create table if not exists code_refs (
  path   text not null references code_files(path) on delete cascade,
  kind   text not null,
  token  text not null,
  owner  text not null default '',
  count  integer not null default 1,
  lines  integer[] not null default '{}',   -- первые 20 строк вхождения
  detail jsonb,
  primary key (path, kind, token, owner)
);
create index if not exists idx_code_refs_token on code_refs (token);
create index if not exists idx_code_refs_kind on code_refs (kind, token);
create index if not exists idx_code_refs_owner on code_refs (owner) where owner <> '';

-- Факты у запущенного приложения. Обновляются целиком, истории не имеют: это
-- снимок текущего кода, а не внешнего источника.
create table if not exists app_models (
  class_name  text primary key,
  table_name  text,
  path        text,
  primary_key text,
  database    text,                   -- к какому подключению приписана модель
  base        text                    -- ближайший абстрактный предок
);
create index if not exists idx_app_models_table on app_models (table_name);

create table if not exists app_associations (
  class_name  text not null,
  name        text not null,
  macro       text not null,          -- has_many | belongs_to | …
  target      text,                   -- класс на другом конце
  foreign_key text,
  primary key (class_name, name)
);

create table if not exists app_routes (
  verb             text not null default '',
  path             text not null,
  controller       text not null default '',
  action           text not null default '',
  controller_class text,
  route_name       text,
  primary key (verb, path, controller, action)
);

create table if not exists app_controllers (
  class_name text primary key,
  path       text,
  actions    text[] not null default '{}'   -- публичные методы, пригодные в роли действия
);

create table if not exists app_jobs (
  job_key    text not null,
  class_name text not null,
  cron       text,
  places     text[] not null default '{}',  -- в каких средах работа включена ('*' — везде)
  path       text,
  primary key (job_key, class_name, cron)
);

-- Карта «константа -> файл» от автозагрузчика. По ней ссылка на класс
-- превращается в ребро графа «файл -> файл» — бесплатно и точно.
create table if not exists app_constants (
  constant text primary key,
  path     text not null
);
create index if not exists idx_app_constants_path on app_constants (path);

-- Где код выполняется: среды и состав служб, снятый с живых контейнеров.
create table if not exists run_places (
  place     text primary key,
  env_id    text not null,            -- чем среда опознаётся внутри приложения
  ssh_host  text,
  container text
);

create table if not exists run_units (
  place     text not null,
  unit      text not null,
  command   text,
  task      text,                     -- если служба запускает задачу сборщика — её имя
  taken_at  timestamptz not null default now(),
  primary key (place, unit)
);

-- Ключи, реально встреченные внутри бесхемных полей. Не схема, а выборка.
create table if not exists json_keys (
  source      text not null,
  table_name  text not null,
  column_name text not null,
  key         text not null,
  hits        integer not null default 0,
  sampled_at  timestamptz not null default now(),
  primary key (source, table_name, column_name, key)
);
create index if not exists idx_json_keys_key on json_keys (key);

-- Что рисовалось в бою: шаблон и действие, из которого он нарисован.
create table if not exists view_runtime (
  place    text not null,
  host     text not null,
  day      date not null,
  action   text not null default '',
  template text not null,
  path     text,                      -- шаблон, приведённый к пути в репозитории
  hits     integer not null default 0,
  primary key (place, host, day, action, template)
);
create index if not exists idx_view_runtime_path on view_runtime (path);

-- Какие действия ЗАПРАШИВАЛИ. Отдельно от отрисовок: действие, отвечающее
-- переходом или json-ом, шаблонов не рисует и по view_runtime неотличимо от
-- мёртвого. Без этой таблицы корень сайта попадает в мёртвые.
create table if not exists action_runtime (
  place  text not null,
  host   text not null,
  day    date not null,
  action text not null,
  hits   integer not null default 0,
  primary key (place, host, day, action)
);
create index if not exists idx_action_runtime_action on action_runtime (action);

-- Какие миграции применены в каждой среде. Это ДАННЫЕ, а не схема: состав
-- применённого лежит в таблице, и спрашивать его надо отдельно.
create table if not exists db_migrations (
  source     text not null,
  version    text not null,
  checked_at timestamptz not null default now(),
  primary key (source, version)
);

-- Какие ключи окружения ЗАДАНЫ в среде. Только ИМЕНА: значения режутся на узле,
-- до отправки, и в индексе их нет.
create table if not exists env_keys (
  place      text not null,
  name       text not null,
  checked_at timestamptz not null default now(),
  primary key (place, name)
);

-- Что лежит в хранилище переводов, по языкам. Читается из файлов, МИНУЯ
-- библиотеку: запасные языки прячут пропуск.
create table if not exists locale_keys (
  lang text not null,
  key  text not null,
  file text not null,
  primary key (lang, key, file)
);
create index if not exists idx_locale_keys_key on locale_keys (key);

-- Узоры ВЫПОЛНЕННЫХ запросов из логов. Значений тут нет: литералы заменяются на
-- узле, до отправки. Это единственный источник, который знает РАЗРЕШЁННОЕ имя
-- таблицы там, где код собирает его интерполяцией.
create table if not exists sql_runtime (
  place    text not null,
  host     text not null,
  day      date not null,
  digest   text not null,              -- sha1 узора: ключ строки
  skeleton text not null,
  hits     bigint not null,
  tables   text[] not null default '{}',
  columns  text[] not null default '{}',   -- названы в списке вывода: слабо
  filters  text[] not null default '{}',   -- участвуют в условии: сильно
  writes   text[] not null default '{}',
  parsed   boolean not null default false, -- узор обрезан и не разобрался
  primary key (place, host, day, digest)
);

-- Заполненность колонок ЖИВЫМИ данными: третий уровень доказательства рядом с
-- кодом и схемой. `filled` — есть значение; `off_default` — отличается от
-- умолчания (при `default 1` первое число бесполезно); `filled_recent` — у
-- свежей когорты, иначе умершая механика неотличима от живой.
create table if not exists column_fill (
  source        text not null,
  table_name    text not null,
  column_name   text not null,
  rows_total    bigint not null,
  rows_recent   bigint,
  filled        bigint not null,
  off_default   bigint,
  filled_recent bigint,
  recent_by     text,                   -- по какой колонке считалась когорта
  measured_at   timestamptz not null default now(),
  primary key (source, table_name, column_name)
);

-- Сканирования индексов. `since` обязателен: перезапуск базы обнуляет счётчики,
-- и без даты «ноль сканирований» не значит ничего.
create table if not exists index_usage (
  source      text not null,
  table_name  text not null,
  index_name  text not null,
  scans       bigint not null,
  size_bytes  bigint not null,
  is_unique   boolean not null default false,
  is_primary  boolean not null default false,
  since       timestamptz,
  measured_at timestamptz not null default now(),
  primary key (source, table_name, index_name)
);

-- Журнал проверок находок (VI.3). Разряд и предмет — опознание находки;
-- `file_sha` — содержимое файла на момент проверки, и без него вердикт «ложная»
-- прячет находку вечно, в том числе настоящую беду, появившуюся на том же месте
-- позже. Внешнего ключа на code_files тут НЕТ намеренно: файл может исчезнуть, а
-- вердикт о нём обязан остаться и сказать это вслух.
create table if not exists finding_verdicts (
  kind       text not null,          -- разряд находок: см. реестр разрядов
  subject    text not null,          -- чем находка опознаётся внутри разряда
  verdict    text not null,          -- 'настоящая' | 'ложная'
  checked    text not null default 'глазами',  -- исполнением | схемой | данными | логами | спекой
  reason     text not null default '',
  path       text,                   -- файл, по правке которого вердикт устареет; null — не стареет
  file_sha   text,
  git_sha    text,
  checked_at timestamptz not null default now(),
  primary key (kind, subject)
);
```

**Правила обращения с этой схемой** — четыре, и все четыре выстраданы:

1. **DDL накатывается на каждом запуске и идемпотентен**: `create table if not
   exists`, `alter table … add column if not exists`. Миграций у инструмента
   анализа быть не должно: он обязан переживать переключение ветки в обе стороны.
2. **Представления сносятся все и создаются заново**, одним блоком перед их
   созданием. `create or replace view` не умеет менять состав и порядок колонок,
   а они будут меняться постоянно. Снос — `drop view if exists … cascade` в
   порядке, обратном зависимостям.
3. **Блокировка вокруг накатывания** (`pg_advisory_lock` с фиксированным
   ключом): в одном дереве работают несколько процессов, и два одновременных
   сноса представлений дают гонку.
4. **Отдельное подключение** от приложения — чтобы ничего не подмешивать в его
   пул и его базу. В Rails это абстрактный класс с `establish_connection`.

## III.2. Виды записей `code_refs`

Главный контракт инструмента: по нему разборщик и отчёты сходятся. Если он не
зафиксирован, соединения не сойдутся и отчёты начнут врать.

Правило, которому подчинён весь список: **надёжность записи — часть записи.**
Факт, догадка и совпадение по тексту не смешиваются ни в одном отчёте.

| `kind` | `token` | `owner` | `detail` | Надёжность |
| --- | --- | --- | --- | --- |
| `pg_table` | имя таблицы | `''` | — | **факт**: SQL разобран парсером базы |
| `pg_column` | имя колонки | таблица или `''`, если не определилась | — | **факт** |
| `ar_column` | имя колонки | таблица модели или `''` | — | факт, если корень цепочки — класс модели |
| `json_key` | ключ | `таблица.колонка` (неизвестная часть — `?`) | — | **факт** |
| `def` | имя метода | класс-владелец или `''` | `sql`, `returns`, `returns_part`, `singleton`, `visibility`, `params[]` | **факт** |
| `assign` | имя переменной | область (`Класс#метод`) | `value`, `sql`, `part`, `op`, `literal`, `carrier`, `from`, `const`, `holes[]`, `more[]` | **факт** |
| `sql_hole` | корень выражения | место в запросе (III.2.1) | `expr`, `scope`, `scopes[]`, `blind`, `fragment`, `carrier`, `call`, `const`, `sql` | **факт о подстановке** |
| `const_ref` | имя константы | область (для задач сборщика — имя задачи) | — | факт ссылки, не вызова |
| `view_name` | логическое имя шаблона | `''` | — | факт |
| `render_ref` | имя шаблона | `''` | — | **факт**: имя стоит в коде целиком |
| `render_dynamic` | узор или выражение | `skeleton`, если узор есть; иначе `''` | `glob`, `source`, `expr`, `root`, `scope` | **кандидат** либо честное «не знаю» |
| `task_entry` | имя задачи сборщика | `''` | — | факт |
| `hb_table` / `hb_column` | таблица / `семейство:колонка` | `''` / таблица | — | факт (литералы в вызовах) |
| `css_class` / `css_id` | имя класса / идентификатора селектора | `''` | — | **факт**: правило объявлено в этом файле |
| `css_import` | путь, куда ведёт `@import`/`@use` | `''` | — | **факт**: цель разрешена в дереве |
| `css_package` | ссылка на ПАКЕТ (`tailwindcss`) | `''` | — | факт: содержимое пакета не читается |
| `css_import_missing` | цель, которой в дереве нет | `''` | — | **находка**, а не ребро |
| `css_apply` | имя класса внутри `@apply` | `''` | — | **факт**: класс поминает сам стиль |
| `html_class` | имя класса из разметки или кода | `''` | — | **факт**: литерал в `class=`, `classList.add`, `data-…-class` |
| `html_class_pattern` | узор имени (`btn-$1`) | `''` | `glob` | **кандидат** |
| `html_class_dynamic` | выражение целиком | `''` | — | **слепое место** |
| `pack_ref` / `pack_dynamic` | имя пака, названное шаблоном | `''` | — | факт / слепое место |
| `js_entry` | путь корня сборки | `bundler` \| `package.json` | `pack`, `assembled` | факт из конфига сборщика |
| `js_import` / `js_package` / `js_import_missing` | путь в дереве / имя пакета / неразрешённая цель | `''` | — | ребро / внешняя зависимость / **находка** |
| `js_func` | имя функции верхнего уровня | область (`Класс`) | — | факт объявления |
| `js_call` | имя в позиции вызова | `''` | — | **зацепка**: имя — плохой ключ и здесь |
| `js_binding` | имя привязки импорта | пакет или путь | `mentions` | факт: через него считается, зовут ли библиотеку |
| `stimulus_register` / `stimulus_use` / `stimulus_target` / `stimulus_value` | имя контроллера, цели, значения | способ включения | — | факт: реестр и разметка |
| `pg_table_guess` | имя после `from`/`join` | `''` | — | **догадка**: SQL не разобрался |
| `token` | имя, известное базе, встреченное в тексте | `''` | — | **кандидат** |
| `sql_blind` | начало неразобранного запроса | `''` | `error` | **слепое место** |
| `hb_dynamic` | имя обёртки или `колонка X` | таблица или `''` | `expr`, `skeleton`, `scope` | **слепое место** |
| `scan_error` | класс ошибки | `''` | `message` | **слепое место** |

### III.2.1. Места подстановки

`owner` у `sql_hole` — место в запросе. Перечень закрытый; порядок определения
важен (IV.3).

| Значение | Что значит | Насколько опасно |
| --- | --- | --- |
| `table` | подставляется имя таблицы | индекс не знает, какую таблицу трогает код |
| `glue` | подстановка приросла к имени | то же, плюс шарды |
| `in_list` | внутри `in (…)` | может прийти целый подзапрос |
| `condition` | целое условие после `where`/`and`/`or`/`on`/`having` | смысл запроса задаёт не эта строка |
| `order_by`, `group_by` | порядок или группировка | подставляется имя колонки |
| `set` | присваивание в `update` | то же |
| `select_list` | список выбираемых полей | то же |
| `values` | внутри `values (…)` | значение |
| `value` | справа от сравнения | значение |
| `limit` | предел выборки | значение |
| `quoted` | внутри кавычек | значение |
| `other` | не распознано | смотреть глазами |

### III.2.2. Дедупликация и слияние

Ключ `(path, kind, token, owner)`. При повторном вхождении: `count += 1`, строка
добавляется в `lines` (до двадцати). `detail` берётся от первого вхождения, но
два поля накапливаются, иначе запись врёт:

- **`more`** — другие выражения или значения с тем же ключом. `ids.join(',')` и
  `ids.map(&:to_i).join(',')` — один корень, разный смысл;
- **`scopes`** — другие области. Одна и та же подстановка в трёх методах файла
  даёт один ряд, и `scope` от первого из них про остальные врёт.

```ruby
def add(kind, token, owner, line, detail: nil)
  token = token.to_s
  return if token.empty?

  ref = (@refs[[kind, token, owner.to_s]] ||= Ref.new(kind, token, owner.to_s, [], 0, detail))
  ref.count += 1
  ref.lines << line if ref.lines.size < MAX_LINES
  merge_detail(ref, detail) if detail && ref.detail && !ref.detail.equal?(detail)
end

def merge_detail(ref, detail)
  text = detail[:expr] || detail[:value]
  collect(ref.detail, :more, text) unless ref.detail[:expr] == text || ref.detail[:value] == text
  collect(ref.detail, :scopes, detail[:scope]) unless ref.detail[:scope] == detail[:scope]
end

def collect(store, key, text)
  return if text.blank?

  list = (store[key] ||= [])
  list << text if list.size < 4 && !list.include?(text)
end
```

## III.3. Конфигурация

Один файл — единственный источник правды об адресах, источниках и правилах.
Пример полный; имена сред условны.

```yaml
# Куда складывать индекс. Отдельная база, к приложению отношения не имеет.
store_url: <%= ENV.fetch('XREF_DATABASE_URL', 'postgresql:///xref') %>

# Схема снимается с каждого источника ОТДЕЛЬНО: «схемы вообще» не существует.
# transport:
#   activerecord  — подключением приложения (локальная база)
#   ssh_psql      — ssh <ssh_host> docker exec -i <container> psql …
#   structure_sql — дамп схемы, загруженный во временную базу
#   thrift        — колоночная база
sources:
  repo:
    kind: pg
    transport: structure_sql
    path: db/structure.sql
    scratch_database: xref_repo
    comment: схема из репозитория — такой же источник, как живые

  local:
    kind: pg
    transport: activerecord
    comment: база разработки

  prod_a:
    kind: pg
    transport: ssh_psql
    ssh_host: node-a1            # узел, где живёт ВЕДУЩАЯ база, не реплика
    container: pg_primary        # ОБРАЗЕЦ имени, не точное имя: см. IV.1
    user: postgres
    database: app
    comment: >-
      снимать только с ведущей: реплика отстаёт, и после миграции вы получите
      ложное «колонки нет»

  prod_b:
    kind: pg
    transport: ssh_psql
    ssh_host: node-b1
    container: pg_primary
    user: postgres
    database: app

  stage:
    kind: pg
    transport: ssh_psql
    ssh_host: stage-1
    container: app_runtime       # psql внутри контейнера приложения
    user: app
    database: app

# Откуда брать ключи внутри бесхемных полей. Схемы у них нет: есть только то,
# что реально лежит. Опрашивать НЕСКОЛЬКО сред и помечать источник — если данные
# в средах разные, ключ со стенда это след опытов, а не боевой факт.
json_sampling:
  sources: [prod_a, prod_b, stage]
  rows: 5000
  statement_timeout: 20s

# Боевые логи: где лежат и на каких узлах. DATE подставляется датой.
view_logs:
  places:
    prod_a:
      glob: '/var/log/app/DATE-web-*.log'
      hosts: [node-a1, node-a2, node-a3]
    prod_b:
      glob: '/var/log/app/DATE-web-*.log'
      hosts: [node-b1, node-b2]

# Где что выполняется. Состав служб снимается с живых контейнеров: инвентарь,
# который ведут руками, отстаёт всегда. Имена мест совпадают с именами
# источников схем — иначе отчёты не соединить.
run_places:
  prod_a:
    ssh_host: node-a1
    container_match: '^app_runtime'
    env_id: '2'
  prod_b:
    ssh_host: node-b1
    container_match: '^app_runtime'
    env_id: '3'

# Архитектурные правила: ребро графа из `from` в `to` — нарушение.
# `limit` — ЗАЩЁЛКА, а не норма: столько терпим сегодня. Отчёт молчит, пока
# число не выросло, и кричит на первом новом. Без защёлки правило с тремя
# сотнями старых нарушений перестают читать в первый же день.
rules:
  - name: миграция не должна знать про модели
    from: 'db/migrate/%'
    to: 'app/models/%'
    why: модель переименуют — реплей миграции упадёт посреди выкатки
    limit: 7
  - name: модель не должна тянуть контроллер
    from: 'app/models/%'
    to: 'app/controllers/%'
    why: обратная зависимость; из фонового процесса контроллера нет
    limit: 3
  - name: старый слой интерфейса не должен ссылаться на новый
    from: 'app/views/legacy/%'
    to: 'app/views/current/%'
    why: это не нарушение, а мера незаконченного переноса — число должно падать
    limit: 389
```

---

## III.4. Повадки дерева — в конфигурацию, а не в разборщик

Самая незаметная причина непереносимости. В разборщике неизбежно оседает знание
о КОНКРЕТНОМ дереве, и выглядит оно как обычный код:

- какими методами тут берут строку-ответ из базы (`select_all`, `find_by_sql`,
  а у нас ещё и `MemberInfo.all`);
- как принято называть переменную со строкой ответа (`row`, `info`, `anketa`);
- какие обёртки колоночной базы первым аргументом принимают ТАБЛИЦУ;
- какие слова после `from` таблицей не являются (`lateral`, `unnest`, `cohort`);
- где лежат переводы (`config/locales`, а у нас ещё `config/site_locales`);
- считать ли не-ASCII в строке, похожей на запрос, признаком ПРОЗЫ.

Последнее — хороший пример того, почему это не настройка вкуса: в русском дереве
«Select a valid review status» надо отличать от SQL по наличию кириллицы в
соседних строках, а в проекте на одном английском это правило не сработает
никогда и только вводит в заблуждение.

**Умолчания — в коде, повадки — в конфигурации.** Инструмент должен работать в
проекте без настройки вовсе (иначе его не попробуют), поэтому в коде лежит
обобщённый набор, а файл настроек его заменяет. Проверка: спека подменяет
повадки и убеждается, что РЕЗУЛЬТАТ разбора меняется — иначе «настройка» есть,
а действия у неё нет (мы такое уже ловили: список вернули, а потребителя списка
забыли, и выглядело как работающая доработка).

**И повадки — это ВХОД разбора.** Добавили имя в список имён строки-ответа —
чтений колонок стало больше при неизменных файлах. Поэтому отпечаток входов
обязан включать и повадки, иначе правка настроек не вызывает переразбора, а
отчёт продолжает считать по прежним правилам и выглядит свежим.

**Числа в подписях — из данных, а не из памяти.** Подпись «общий legacy на 18
языках» в чужом проекте с двумя языками утверждала неправду; теперь число
языков считается запросом. Любое число, вшитое в текст отчёта, — это утверждение
о дереве, и оно устареет.

---

# Часть IV. Сбор

## IV.1. Схемы сред

**Один запрос к системному каталогу**, а не к переносимым представлениям: нужен
вид объекта, и один и тот же запрос обязан работать на всех версиях, какие у вас
живут. Отдаёт один документ JSON — его проще передать и сохранить.

```sql
select json_build_object(
  'server_version', current_setting('server_version'),
  'database', current_database(),
  'tables', coalesce((select json_agg(t) from (
      select c.relname as name, c.relkind::text as kind, c.reltuples::bigint as est_rows
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r','p','v','m','f')
      order by c.relname) t), '[]'::json),
  'columns', coalesce((select json_agg(c) from (
      select cl.relname as table_name, a.attname as column_name, a.attnum as ordinal,
             format_type(a.atttypid, a.atttypmod) as data_type,
             a.attnotnull as not_null,
             pg_get_expr(d.adbin, d.adrelid) as default_expr
      from pg_attribute a
      join pg_class cl on cl.oid = a.attrelid
      join pg_namespace n on n.oid = cl.relnamespace
      left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
      where n.nspname = 'public' and a.attnum > 0 and not a.attisdropped
        and cl.relkind in ('r','p','v','m','f')
      order by cl.relname, a.attnum) c), '[]'::json),
  'indexes', coalesce((select json_agg(i) from (
      select t.relname as table_name, ir.relname as index_name,
             ix.indisunique as is_unique, ix.indisprimary as is_primary,
             pg_get_indexdef(ir.oid) as definition
      from pg_index ix
      join pg_class ir on ir.oid = ix.indexrelid
      join pg_class t on t.oid = ix.indrelid
      join pg_namespace n on n.oid = t.relnamespace
      where n.nspname = 'public'
      order by t.relname, ir.relname) i), '[]'::json)
)
```

**Транспорт до боя.** Прямого хода к базе обычно нет: контейнер публикует не тот
порт, а до самого порта базы с рабочей машины хода нет. Не изобретайте туннель —
зайдите по ssh и выполните клиент базы внутри контейнера, запрос передайте на
stdin:

```ruby
def ssh_psql(sql)
  out, err, status = Open3.capture3(
    'ssh', '-o', "ConnectTimeout=#{CONNECT_TIMEOUT}", '-o', 'BatchMode=yes',
    cfg[:ssh_host].to_s, remote_psql_script,
    stdin_data: sql
  )
  raise Error, "#{name}: ssh вернул #{status.exitstatus}: #{err.strip.lines.last(3).join(' ')}" unless status.success?

  out
end

# Имя контейнера в конфиге — ОБРАЗЕЦ, а не точное имя. В оркестраторе имя несёт
# хвост задачи (`pg_primary.1.new3ic22ln…`) и меняется при каждом перезапуске
# службы. Резолвим на той стороне. Пока этого не было, обновление схем молча
# отвалилось, и индекс неделю отвечал по старому снимку.
def remote_psql_script
  match = Shellwords.escape("^#{Regexp.escape(cfg[:container].to_s)}(\\.|$)")
  psql = Shellwords.join(['psql', '-U', cfg[:user].to_s, '-d', cfg[:database].to_s,
                          '-At', '-q', '-f', '-'])
  <<~SH
    c=$(docker ps --format '{{.Names}}' | grep -E #{match} | head -1)
    if [ -z "$c" ]; then echo "контейнер по образцу не найден" >&2; exit 1; fi
    exec docker exec -i "$c" #{psql}
  SH
end
```

**Дамп схемы из репозитория не парсите.** Загрузите его во временную базу и
снимите тем же запросом, что и живые. Иначе в проекте появится второй,
самодельный разборщик схемы, и он разойдётся с настоящим. Побочная выгода: дамп и
локальная база начинают проверять друг друга.

**Неудачный снимок — тоже ряд** в `snapshots` (`ok = false`, текст ошибки).
Иначе отвалившийся источник не отличить от источника, которого нет, и отчёты
начинают молча отвечать по старому снимку. Возраст снимка показывайте в отчётах о
расхождениях.

**Снимайте не только структуру, но и КОД внутри базы.** Правила перезаписи,
триггеры, функции, ограничения, последовательности. Это не полнота ради полноты:

- **правило перезаписи меняет смысл запроса.** `ON INSERT … DO INSTEAD UPDATE` —
  вставка оказывается обновлением. У нас таких правил 59, и почти все —
  накопители вида `SET x = x + new.x`, то есть колонку, которую правило
  увеличивает, оно же и ЧИТАЕТ. Пока тела правил не разбирались, 165 колонок
  выглядели нечитаемыми — ошибка в опасную сторону: «можно удалить»;
- **тела разбирайте тем же парсером**, которым разбираете код, и записывайте с
  владельцем «правило X» вместо пути файла. Своего второго разборщика тут быть не
  должно. Тонкость: у `CREATE RULE` действия лежат во ВЛОЖЕННЫХ узлах, и обходить
  надо их, иначе цели записи внутри правила не видны;
- **тело на процедурном языке парсер базы не разберёт** — он знает только внешний
  `CREATE FUNCTION`. Такие помечайте отдельным, более слабым разрядом «не
  разобрано, язык такой-то», а не молчанием;
- **ограничение — потребитель колонки.** Имена колонок берите из каталога, а не
  регуляркой по тексту определения: `CHECK ((age > 0))` регулярке не поддаётся.
  `NOT NULL` и первичный ключ из потребителей исключите — это свойство, а не
  ссылка. И помните, что свежие версии базы держат `NOT NULL` в том же каталоге
  ограничений, что и всё остальное;
- **у таблицы с правилом перезаписи предупреждение печатайте ПЕРВОЙ строкой**
  отчёта, до остального: иначе читатель успеет сделать вывод из цифр, которые
  правило меняет.

## IV.2. Разбор кода: инкрементальный цикл

Сто строк, которые меняют всё: индекс можно догонять **перед каждым запросом**, и
дисциплина «не забыть переиндексировать» исчезает.

```ruby
def scan_code(full: false)
  Store.migrate!
  known         = Store.known_names        # имена колонок и таблиц из снимков
  model_tables  = Store.model_tables       # Класс -> таблица
  app_constants = Store.app_constant_names # имена констант от автозагрузчика

  # РАСШИРЕНИЯ — ЭТО ВОРОТА ЗНАНИЯ, и ошибка здесь не похожа на остальные:
  # отсутствующее расширение не делает ответ беднее, оно делает его ЛОЖНЫМ.
  # Разборщик видит половину связки и уверенно докладывает о дефекте. В проекте
  # на TypeScript (09.10.2026) `.ts/.tsx` в этом списке не было, и отчёт выдал
  # шесть находок: три «контроллер не зарегистрирован» при регистрации в
  # `application.ts` и три «метода нет» при существующих методах.
  # Признак такой поломки — НОЛЬ в счётчике слоя (ноль контроллеров, ноль
  # ключей из шаблонов, ноль классов). Ноль в самодиагностике проверяйте первым.
  extensions = %w[.rb .rake .ru .erb .haml .slim .builder .jbuilder
                  .js .jsx .mjs .ts .tsx .mts .sql
                  .css .scss .sass .less
                  .md .markdown .yml .yaml .json .sh .bash .conf]
  # Дампы схемы — это схема, а не код, который её трогает: в дампе лежат все
  # шардированные таблицы, и все они попадут в «код обращается к таблице».
  # Свои же файлы индекс не разбирает: его DDL — про другую базу.
  skip = %r{\A(vendor/|node_modules/|public/|db/[^/]+\.sql\z|lib/xref/|lib/tasks/xref\.rake\z)}

  files = `git ls-files -z`.split("\0")
          .select { |f| extensions.include?(File.extname(f)) }
          .reject { |f| f.match?(skip) }

  current = files.each_with_object({}) do |f, acc|
    acc[f] = Digest::SHA1.file(f).hexdigest if File.file?(f)
  end

  # Отпечаток входов: сменилась схема или факты приложения — разбирать надо ВСЁ,
  # хотя ни один файл не менялся.
  inputs = Store.input_digest(known: known, model_tables: model_tables,
                              app_constants: app_constants)

  stored  = Store.code_file_shas          # path => [sha файла, отпечаток входов]
  # Исчезнувшие считаем ВСЕГДА, в том числе при полном пересборе: иначе остаются
  # ряды от файлов, которые из обхода выпали.
  removed = stored.keys - current.keys
  changed = full ? current : current.reject { |path, sha| stored[path] == [sha, inputs] }

  Store.delete_code_files(removed) if removed.any?
  changed.each do |path, sha|
    source = File.read(path, encoding: 'UTF-8').scrub('')
    refs = CodeScanner.new(path, source, known: known, model_tables: model_tables,
                                         app_constants: app_constants).scan
    Store.write_code_file(path, sha: sha, lang: CodeScanner.language(path),
                                bytes: File.size(path), refs: refs)
  end
end
```

Запись одного файла — удалить его записи и вставить новые **в одной транзакции**:
прерванный разбор не должен оставлять файл с половиной записей.

**В отпечаток входов обязана входить и сумма САМОГО РАЗБОРЩИКА**: правка правил
разбора меняет результат при неизменных файлах дерева ровно так же, как смена
схемы. Считать её по всему каталогу инструмента — дорого (у нас правка отчёта
заставляла переразбирать 21 494 файла, 200 секунд), поэтому берутся только
УЧАСТНИКИ разбора. И тут две дыры, обе наши:

- **сузиться молча нельзя.** Если хоть одного названного участника на месте нет
  (переименовали, разнесли), отпечаток считается по всему каталогу: ворота
  ломаются в сторону лишней работы, а не пропущенной правки;
- **пополнять список руками — та же дыра с другой стороны.** Мы добавили слой
  стилей и забыли вписать его разборщик: сутки правка правил разбора стилей не
  вызывала переразбора вовсе, а отчёт выглядел свежим. Лечится не
  внимательностью, а проверкой: состав участников сверяется с тем, КОГО
  разборщик реально зовёт (разбор своего же исходника — дёшево и точно), и это
  спека, доказанная снятием.

## IV.3. Разбор SQL: подстановка и место в запросе

Самая тонкая часть. Здесь легче всего получить инструмент, который выдумывает
имена таблиц, — и не заметить этого.

**Дыра — это `$1`, а не `1`.** С единицей строка `"… from shard_#{n}"`
разбирается как таблица `shard_1`: индекс молча выдумывает имена, которых нет.
`$1` в позиции значения законен, а в позиции имени ломает разбор — и место честно
уходит в слепые зоны. Одного `$1` недостаточно: в идентификаторах PostgreSQL
символ `$` допустим, поэтому отдельно ловится **прирастание дыры к имени**.

```ruby
SQL_HOLE = '$1'
QUESTION_PLACEHOLDER = /(?<=[\s,(=<>])\?(?=[\s,)]|\z)/   # `where id = ?` — тоже подстановка
SQL_START = /\A\s*(select\s|insert\s+into\s|update\s+[a-z_"]|delete\s+from\s|with\s+[a-z_"])/i
IDENT_HEAD = /\A[A-Za-z0-9_$]/
IDENT_TAIL = /[A-Za-z0-9_$]\z/

# Грубая проверка «мы внутри строкового литерала»: внутри кавычек склейка
# `'%$1%'` безобидна, а `tbl$1` снаружи — уже выдуманное имя.
def inside_string_literal?(text)
  text.count("'").odd?
end
```

**Сборка интерполированной строки.** Возвращает четыре значения: текст,
был ли интерполяция, приросла ли дыра к имени, и сами дыры со смещениями.

```ruby
# => [текст, была_ли_интерполяция, приросла_ли_дыра_к_имени, дыры]
# дыра: { expr: 'ids.join(",")', offset: 42, line: 17 }
def literal(node)
  case node
  when StringNode, SymbolNode
    [node.unescaped.scrub(''), false]
  when InterpolatedStringNode
    interpolated = false
    merged = false
    holes = []
    text = +''
    node.parts.each do |part|
      case part
      when StringNode
        chunk = part.unescaped.scrub('')
        merged ||= text.end_with?(SQL_HOLE) && chunk.match?(IDENT_HEAD) && !inside_string_literal?(text)
        text << chunk
      when InterpolatedStringNode
        # Соседние литералы, склеенные переносом строки (`"a " \` / `"b#{x}"`),
        # парсер отдаёт ВЛОЖЕННЫМИ узлами. Пока это не разворачивалось, каждая
        # такая часть схлопывалась в одну дыру целиком: из
        # `"INSERT … VALUES " "(#{a}, #{b})"` получалось `INSERT … VALUES $1`,
        # то есть половина запроса исчезала, и запрос уходил в слепые зоны.
        inner, inner_interp, inner_merged, inner_holes = literal(part)
        interpolated ||= inner_interp
        merged ||= inner_merged
        merged ||= text.match?(IDENT_TAIL) && inner.start_with?(SQL_HOLE) && !inside_string_literal?(text)
        merged ||= text.end_with?(SQL_HOLE) && inner.match?(IDENT_HEAD) && !inside_string_literal?(text)
        Array(inner_holes).each { |hole| holes << hole.merge(offset: text.length + hole[:offset]) }
        text << inner
      else
        interpolated = true
        merged ||= text.match?(IDENT_TAIL) && !inside_string_literal?(text)
        # Строка у дыры СВОЯ, а не начало литерала: у многострочного запроса
        # все дыры иначе показываются на первой строке, и найти их нельзя.
        holes << { expr: hole_expression(part), offset: text.length,
                   line: part.location.start_line }
        text << SQL_HOLE
      end
    end
    [text, interpolated, merged, holes]
  end
end
```

Части склейки надо помечать как «не самостоятельные строки» и не разбирать
отдельно — иначе обрубок уйдёт в слепые зоны рядом с целым запросом. Пометка
рекурсивная: вложенность бывает глубже одного уровня.

**Место подстановки** определяется по тексту слева. Порядок проверок значим: это
не стилистика, а правильность. `where id in (` — это `in_list`, а не `condition`;
`from ` — `table`, а `from users_` — `glue`.

```ruby
def hole_context(sql, offset)
  left = sql[0, offset].to_s
  return 'quoted' if inside_string_literal?(left)

  case left.gsub(/\s+/, ' ')
  # Любое место внутри незакрытой `in (…)`, а не только сразу за скобкой: во
  # `in ($1, $1)` вторая дыра такая же, как первая. Но если внутри скобки начался
  # select, мы уже в подзапросе, и место там другое.
  when /\bin\s*\((?![^)]*\bselect\b)[^)(]*\z/i                then 'in_list'
  when /\b(?:from|join|into|update|table)\s+(?:only\s+)?\z/i  then 'table'
  when /\border by [\w.,() ]*\z/i                             then 'order_by'
  when /\bgroup by [\w.,() ]*\z/i                             then 'group_by'
  when /\b(?:limit|offset)\s+\z/i                             then 'limit'
  when /\bvalues\s*(?:\([^)]*)?\z/i                           then 'values'
  when /(?:=|<|>|<=|>=|<>|!=|\blike|\bilike)\s*\z/i           then 'value'
  when /\bset\s+[\w.,'"= ]*\z/i                               then 'set'
  when /\b(?:where|and|or|on|having)\s+\z/i                   then 'condition'
  when /[A-Za-z0-9_$]\z/                                      then 'glue'
  when /\bselect\b/i                                          then 'select_list'
  else 'other'
  end
end
```

**Разбор запроса.** Подстановку заменяем, и только потом отдаём парсеру базы.
Дыры записываются ДО замены вопросительных знаков — иначе смещения съедут.

```ruby
def analyze_sql(sql, line, blind: false, holes: nil)
  @sql_here = true                      # пометка уйдёт в запись `def`
  record_holes(sql, holes, line, blind: blind) if holes.present?
  sql = sql.gsub(QUESTION_PLACEHOLDER, SQL_HOLE)
  # Дыра приросла к имени: разбирать нельзя. `shard_$1` база считает законным
  # идентификатором, и индекс наполнялся бы таблицами, которых не существует.
  return unparsed(sql, line, 'имя собрано интерполяцией') if blind
  return unparsed(sql, line, 'парсер недоступен') unless pg_query?

  parsed  = PgQuery.parse(sql)
  aliases = parsed.aliases
  tables  = parsed.tables.map { |t| unqualify(t) }
  tables.each { |t| add('pg_table', t, '', line) }

  column_refs(parsed).each do |qualifier, column|
    owner = if qualifier.nil?
              tables.size == 1 ? tables.first : ''   # одна таблица — привязка однозначна
            else
              unqualify(aliases[qualifier] || qualifier)
            end
    add('pg_column', column, owner, line)
  end

  json_keys(parsed).each do |base, key|
    next if key.include?(SQL_HOLE)      # ключ собран интерполяцией — это узор, не имя
    table = tables.size == 1 ? tables.first : '?'
    add('json_key', key, "#{table}.#{base.presence || '?'}", line)
  end
rescue StandardError => e
  unparsed(sql, line, e.message)
end

# Разбор не удался: помечаем слепым местом и вынимаем имя таблицы выражением —
# но ОТДЕЛЬНЫМ видом, потому что это догадка.
TABLE_GUESS = /\b(?:from|into|update|join)\s+(?:only\s+)?([a-z_][a-z0-9_]*)/i
GUESS_STOPLIST = %w[set now the only lateral values select where group order limit offset
                    generate_series unnest jsonb_array_elements regexp_split_to_table dual].freeze

def unparsed(sql, line, reason)
  add('sql_blind', sql.gsub(/\s+/, ' ').strip[0, 120], '', line, detail: { error: reason[0, 200] })
  sql.scan(TABLE_GUESS).flatten.map(&:downcase).uniq.each do |guess|
    add('pg_table_guess', guess, '', line) unless GUESS_STOPLIST.include?(guess)
  end
  nil
end
```

## IV.4. Обрывки запроса

Самый незаметный вид подстановки: `param_ar << "user_id in (#{sub})"`,
`return ["user_id in (#{sql})"] if sql`. Целого запроса рядом нет — ни `select`,
ни `from`, — разбирать нечем, и глаз такое проскакивает легче всего.

Дыра в обрывке записывается наравне с прочими (`fragment: true`), но отбор
жёсткий, иначе это чистый шум:

```ruby
# Обрывок: не предложение, а кусок, который потом склеят.
SQL_FRAGMENT = /
  \A[\s(]*(?:
      (?:and|or|not|where|having|order\s+by|group\s+by|limit|offset|set|values|
         union|from|join|inner\s+join|left\s+join|right\s+join|on)\b
    | [a-z_][a-z0-9_."]*\s+(?:not\s+)?(?:in\s*\(|like\b|ilike\b|is\b|between\b)
  )
/xi
# Ветки `имя = …` тут нарочно НЕТ. С ней в индекс шли строки лога и параметры
# URL: `"trace=#{id} n=#{n}"`, `"flm=#{a}&intp=#{b}"`, человеческое
# `"From #{кто} on balance"` — шестнадцать ложных находок из ста семи.

# Признак настоящего SQL, и признак сильный: `from` в него не входит нарочно —
# на нём в индекс шло человеческое «From … on balance».
SQL_PART_MARK = /\b(?:select|where|join)\b|\bin\s*\(/i

# Места, ради которых обрывок вообще разбирается. `value`, `quoted`, `limit` и
# `select_list` сюда не входят: там подставляется значение, а обрывков со
# значениями в коде десятки тысяч.
FRAGMENT_CONTEXTS = %w[in_list condition table glue order_by group_by set values].freeze
# …а этим двум признак SQL не нужен: «order by» посреди обычного текста не
# встречается.
FRAGMENT_SELF_EVIDENT = %w[order_by group_by].freeze
```

Запись дыры с воротами:

```ruby
def record_holes(sql, holes, line, blind:, carrier: nil, fragment: false)
  whole  = sql.gsub(/\s+/, ' ').strip[0, 200]
  marked = fragment && sql.match?(SQL_PART_MARK)
  holes.each do |hole|
    expr = hole[:expr].to_s
    next if expr.empty?

    context = hole_context(sql, hole[:offset])
    if fragment
      next unless FRAGMENT_CONTEXTS.include?(context)
      next if !marked && !FRAGMENT_SELF_EVIDENT.include?(context)
    end

    root = hole_root(expr)
    hole_line = hole[:line] || line
    # Одна и та же дыра может прийти дважды (обрывок разбирается и сам по себе,
    # и как значение присваивания) — один ряд, а не два вхождения.
    next unless @recorded_holes.add?([hole_line, hole[:offset], root])

    @wanted_roots << root unless root.empty?
    add('sql_hole', root.presence || expr[0, 60], context, hole_line,
        detail: { expr: expr[0, 200], scope: scope_name, blind: blind, sql: whole,
                  carrier: carrier, fragment: fragment,
                  call: expr_call(expr), const: (root if root.match?(/\A[A-Z]/)) })
  end
end

# Корень выражения: то имя, по которому его вообще можно искать.
# `ids.map(&:to_i).join(',')` -> `ids`, `params[:sort]` -> `params`.
HOLE_ROOT = /\A[@$]{0,2}[A-Za-z_][A-Za-z0-9_]*[!?]?/
def hole_root(expr) = HOLE_ROOT.match(expr.to_s)&.to_s.to_s

# `Repo.new.take_all` — носитель не класс, а его метод. Корень тут константа, и
# по ней метод не найти: искать надо `take_all`. У `ids.map(&:to_i)` корень
# строчный — там последний вызов это `map`, и искать по нему нечего.
def expr_call(expr)
  head = expr.to_s[/\A[A-Za-z_][\w:]*(?:\s*\.\s*[a-z_]\w*[!?]?)+/]
  return nil if head.nil? || !head.match?(/\A[A-Z]/)

  parts = head.split('.').map(&:strip)
  parts.pop if parts.size > 2 && parts.last == 'new'
  parts.last == 'new' ? nil : parts.last
end
```

**Переменная, накапливающая запрос.** `sql = 'select …'` затем
`sql << " where id in (#{ids})"` — самый частый способ собрать запрос по кускам.
Фрагмент целиком не разобрать, но дыра в нём та же:

```ruby
def note_assign(name, value, line, operator)
  return if value.nil?

  text, interpolated, merged, holes = literal(value)
  source     = value.slice.to_s[0, 400]
  whole_sql  = text.to_s.match?(SQL_START)
  part_sql   = !whole_sql && text.to_s.match?(SQL_FRAGMENT) && text.to_s.match?(SQL_PART_MARK)
  # Порядок важен: «несёт запрос» — это про то, что было ДО этой строки.
  carrier    = @sql_vars.include?(name)
  @sql_vars << name if whole_sql

  record_holes(text, holes, line, blind: merged, carrier: name) if carrier && !whole_sql && holes.present?

  @assigns << {
    name: name, line: line, scope: scope_name, operator: operator, carrier: carrier,
    value: (text || source).gsub(/\s+/, ' ').strip[0, 200],
    sql: whole_sql, part: part_sql, literal: !text.nil?, interpolated: interpolated,
    # Значение не строка (`cond = build_cond`) — запоминаем, ЧЕМ оно берётся: по
    # этому имени дыра дотягивается до метода, который её наполняет.
    from: text.nil? ? (expr_call(source) || hole_root(source)) : nil,
    const: (text.nil? && hole_root(source).match?(/\A[A-Z]/) ? hole_root(source) : nil),
    holes: Array(holes).map { |h| h[:expr] }.first(4)
  }
end
```

**Отбор присваиваний.** Записывать все — значит раздуть индекс тем же, чем раздут
поиск по тексту. Запись попадает в индекс, если выполнено хоть одно условие:
значение похоже на запрос; имя подставляется в дыру или в шаблон в этом же файле;
имя видно за границей файла (`@`, `@@`, `$`, константа). Прочие локальные
переменные — шум: их сотни тысяч, а ответить ими не на что.

## IV.5. Объявления: видимость и «возвращает запрос»

**Видимость — ключ к отчёту о неиспользуемом.** У приватного метода «вызовов по
имени нет» почти доказательство: снаружи класса его и не позвать. У публичного то
же самое значит лишь «в этом дереве не зовут». Учесть надо все четыре способа
задать видимость, иначе половина методов будет помечена неверно:

```ruby
VISIBILITY = %w[private protected public].freeze

# `private` меняет видимость всего, что объявлено ниже в ЭТОМ теле; три другие
# формы называют методы поимённо.
def handle_visibility(node)
  name = node.name.to_s
  return unless VISIBILITY.include?(name) || name == 'private_class_method'
  return unless node.receiver.nil?

  level     = name == 'private_class_method' ? 'private' : name
  arguments = node.arguments&.arguments || []
  if arguments.empty?
    @visibility[-1] = level if VISIBILITY.include?(name)   # переключатель в теле класса
    return
  end

  @pending_visibility = level if arguments.any? { |a| a.is_a?(DefNode) }   # `private def x`
  arguments.each do |argument|                                            # `private :x, :y`
    next unless argument.is_a?(SymbolNode) || argument.is_a?(StringNode)

    @visibility_named[[@scope_stack.join('::'), argument.unescaped.to_s]] = level
  end
end
```

Кадр видимости заводится на каждое тело класса и модуля, и **отдельный** — на
блок методов класса (`class << self`): там свой независимый переключатель.
`private :старый_метод` стоит НИЖЕ объявления, поэтому поимённые пометки
применяются после обхода файла, а не во время.

**«Возвращает запрос» и «в теле есть запрос» — разные признаки.** Первое верно
для единиц, второе — почти для любой модели (у нас 75 против 2123). Если
перепутать, в отчёт попадёт пол-репозитория, и его перестанут читать.

```ruby
# => 'whole' | 'part' | nil
def sql_return_kind(node)
  body = node.body
  last = body.is_a?(StatementsNode) ? body.body.last : nil
  # Разматываем хвост вызовов: господствует форма `<<~SQL.squish`, и без
  # разматывания она читается как вызов, а не как строка.
  last = last.receiver while last.is_a?(CallNode) && last.receiver
  case last
  when LocalVariableReadNode, InstanceVariableReadNode
    @sql_vars.include?(last.name.to_s) ? 'whole' : nil
  else
    text, = literal(last)
    return 'whole' if text.to_s.match?(SQL_START)
    # `(user_id in (select …))` — не предложение, а готовое условие. Для дыры
    # разницы нет: подставится кусок запроса.
    return 'part' if text.to_s.match?(SQL_FRAGMENT) && text.to_s.match?(SQL_PART_MARK)

    nil
  end
end
```

Ветвление в конце (`if a then sql1 else sql2 end`) сюда не попадает — известный
недобор. Лучше недобрать, чем позвать в отчёт каждый метод модели.

**Параметры метода записывайте.** Если корень дыры — параметр, значит текст
приходит от вызывающего, и отчёт должен сказать это, а не молчать.

## IV.6. Шаблоны и вызовы отрисовки

**Вызовы отрисовки разбирайте построчно, а не деревом**: в шаблоне код нарезан
тегами, целого дерева там нет. Три исхода на один вызов, и разница между ними —
это разница между фактом и догадкой:

- имя стоит в коде целиком → **факт** (`render_ref`);
- имя собрано интерполяцией, но литеральные куски есть (`"layouts/#{kind}"`) → из
  них собирается узор `layouts/*`, и по узору выдаются рёбра-**кандидаты**;
- имя целиком в переменной → честное **слепое место**: сказать нечего, кроме
  того, что оно есть.

Третий случай обязателен. Пока такие вызовы не попадали в индекс вовсе,
инструмент не говорил «не знаю» — он молчал, и молчание читалось как «связей
нет»: боевое меню сайта с полумиллионом отрисовок в сутки числилось
недостижимым.

Тонкости, без которых разбор теряет две трети вызовов:

- **старая форма с хвостовой стрелкой господствует** (`render :partial => 'x'`),
  и ключей в одном вызове может быть несколько — берите все;
- **проверяйте, что слово стоит в позиции вызова**, а не в тексте страницы и не в
  комментарии: иначе в слепые зоны попадут комментарии и строки-подсказки из
  тестов. Признак — непарные кавычки слева и список допустимых предшественников;
- **узор экранируйте тильдой**, а не обратным слэшем: в именах шаблонов сплошные
  подчёркивания, а для `LIKE` это подстановочный знак. По той же причине суффикс
  имени сравнивайте через `right()`, а не `LIKE`.

**Логическое имя шаблона** — путь без корня шаблонов, ведущего подчёркивания и
расширений. Приставку варианта интерфейса в нём ОСТАВЛЯЙТЕ: сводит варианты не
разборщик, а сравнение по суффиксу в представлении рёбер. Тогда одно имя в коде
ведёт разом во все варианты, а имя файла не теряется.

**Поиск вызовов в шаблонах** (нужен для вопроса «кто зовёт этот помощник»): дерева
парсер не построит, но из тегов собирается настоящий код — ровно так, как это
делает сам шаблонизатор.

```ruby
ERB_TAG = /<%(?<kind>[=\-#]?)(?<code>.*?)-?%>/m

# Текст между тегами выбрасывается, переводы строк СОХРАНЯЮТСЯ (иначе номера
# строк разъедутся с файлом), `<% if %>` и `<% end %>` из разных тегов сходятся
# в одно выражение.
def erb_ruby(source)
  out = +''
  position = 0
  each_erb_tag(source) do |code, _line, match|
    out << ("\n" * source[position...match.begin(0)].to_s.count("\n"))
    out << code << ' ; '
    position = match.end(0)
  end
  out << ("\n" * source[position..].to_s.count("\n"))
  out
end

def each_erb_tag(source)
  source.to_enum(:scan, ERB_TAG).each do
    match = Regexp.last_match
    code  = match[:kind] == '#' ? match[:code].gsub(/[^\n]/, ' ') : match[:code]  # комментарий — пробелами
    yield code, source[0...match.begin(0)].count("\n") + 1, match
  end
end
```

Если целиком не разобралось (тег внутри атрибута, обрывок на два шаблона) —
разберите каждый тег порознь: часть вызовов всё равно видна. Без разбора
шаблонов ответ «кто зовёт» врёт в самую частую сторону: у одного помощника
выходило 4 вызова вместо 19 при трёх тысячах шаблонов рядом.

## IV.7. Факты у запущенного приложения

Самый дешёвый слой и самый недооценённый. Поднимите приложение, дайте догрузить
все классы и спросите у него: модели с таблицами и путями к файлам, связи,
роуты, контроллеры с их действиями, расписание фоновых работ, карту
«константа → файл» от автозагрузчика.

Что важно:

- **не угадывайте то, что можно спросить.** Попытка вычислить «класс `UserProfile`
  лежит в `user_profile.rb`» создаёт второй источник правды, который разойдётся с
  настоящим на первом нестандартном имени;
- **карта констант от автозагрузчика** превращает ссылку на класс в ребро графа
  «файл → файл». Это главный поставщик рёбер;
- **таблицу модели берите у модели**, а не у имени класса. Составной первичный
  ключ приходит массивом — приводите к строке;
- **к какой базе приписана модель** определяйте по ближайшему абстрактному
  предку, а не по текущему подключению: иначе все модели окажутся в основной базе;
- **каждый вызов оборачивайте в защиту**: одна модель, падающая при обращении к
  метаданным, не должна рушить сбор. Неудачу записывайте, а не глотайте.

## IV.8. Где код выполняется

Нужен, если среды больше одной или код расщеплён по ролям (веб, воркеры, фоновые
роботы). Снимите **с живых контейнеров** состав служб: что запущено и какую
задачу выполняет. Инвентарь, который ведут руками, отстаёт всегда.

Соединение этого слоя с первым даёт самый ценный отчёт в наборе: **таблицы в
этой среде нет, а код, который её трогает, именно здесь и выполняется.**

## IV.9. Содержимое бесхемных полей

Для каждого поля-json: выборка строк с ограничением, перечисление ключей
верхнего уровня, подсчёт. По одному оператору на колонку и срок на оператор —
иначе одна тяжёлая колонка убьёт весь сбор. Только чтение.

Собирайте с нескольких сред и **помечайте источник**: ключ, встреченный только на
стенде, — след опытов, а не боевой факт.

## IV.10. Логи боя

**Два разных счётчика за один проход**, и путать их нельзя:

```awk
/ Processing by / { i = index($0, "Processing by "); rest = substr($0, i + 14);
                    j = index(rest, " as "); if (j > 0) rest = substr(rest, 1, j - 1);
                    act = rest; a[act]++; next }
/ Rendered /      { i = index($0, "Rendered "); rest = substr($0, i + 9);
                    if (substr(rest, 1, 7) == "layout ") rest = substr(rest, 8);
                    j = index(rest, " ("); if (j > 0) rest = substr(rest, 1, j - 1);
                    sub(/[ \t]+$/, "", rest); if (rest == "") next; c[act "|" rest]++ }
END { for (k in a) print "A|" k "|" a[k]; for (k in c) print "V|" k "|" c[k] }
```

- `Rendered` — какой шаблон нарисован;
- `Processing by` — какое ДЕЙСТВИЕ запрашивали.

Разница решающая: действие, отвечающее переходом, json-ом или пустым телом,
**не рисует шаблонов** и по первому счётчику выглядит мёртвым. У нас по этой
причине в мёртвые попал корень сайта.

Четыре правила:

1. **Разбирайте на машине, где логи лежат.** Их гигабайты в сутки; обратно едет
   сводка, а не логи. Передавайте скрипт на вход `ssh host sh -s`.
2. **Проверьте, законна ли привязка** шаблона к действию. У нас она точна потому,
   что воркер однопоточный: строки идут строго подряд. Если у вас потоки —
   привязка по соседству неверна, нужен идентификатор запроса в строке лога.
3. **Копите по дням** и храните с разбивкой по среде, узлу и дню. Один день
   доказывает использование и ничего не говорит о смерти.
4. **Пустой ответ не затирает собранное.** Лог за день может лежать на узле и не
   содержать ни одной нужной строки; схема «удалить прежнее и вставить новое»
   пустым списком уничтожит снимок, собранный, когда лог был полным. Так у нас
   пропал собранный ранее день. Правило: нечего вставлять — ничего не удалять, и
   различайте «логов нет» и «в логах ничего не нашлось».

## IV.11. «Какие поля в коде не используются»: имя в списке — не использование

Самый частый вопрос к такому индексу — и самый легко испорченный. Если таблица
выбирается списком полей целиком (`select #{FIELDS} from users`), то «колонка
названа в коде» не значит ничего: список назван один раз и сразу для всех колонок.
Отчёт, построенный на упоминании имени, отвечает «направление не прослежено» и
прячет ответ.

Использование колонки, приехавшей таким запросом, — когда **берут значение**:
`row['nickname']`, `info.fetch(:sex)`, `row.dig('meta')`. Это отдельный вид записи,
и без него ответа нет. Различать надо пять случаев, и использование — первые три:

| вид | пример | использование? |
| --- | --- | --- |
| ключ-литерал | `row['nickname']` | да; связь по ИМЕНИ — таблицы у неё нет, и отчёт обязан это говорить |
| узор ключа или имени | `info["language#{num}_2"]` → `language$1_2` | да, если узор ИЗБИРАТЕЛЬНЫЙ (см. ниже) |
| имя в строке-выражении | `'paid_until-paid_from<…interval'` | да; связь по ИМЕНИ |
| ключ-переменная | `row[field]` в цикле по списку | нет — слепое место; печатайте числом |
| подстановка на месте имени колонки | `"#{make_goal(g)} in (1,2)"` | нет — печатайте с файлом и строкой |

`[]=` в этот счёт не входит: `result['nick'] = …` — запись в свой хеш, а не чтение
колонки.

**Избирательность узора.** Узор, собранный из интерполяции, кажется удобным
доказательством — и ошибается в худшую сторону. У нас узор `user_$1` (из трёх СПЕК, где
строят строку логина `"user_#{user_id}"`) объявил используемыми тринадцать колонок
одного семейства — ровно те, которые не читает никто. Три условия, каждое из настоящего
ложного срабатывания:

1. буквенная часть не пустая — иначе `$1_$1` совпадает с 73 колонками из 99;
2. узор ловит **не больше трёх-четырёх** колонок таблицы: `language$1_2` ловит
   четыре и говорит о них, `user_$1` ловит двадцать и не говорит ни о чём;
3. встречается не только в тестах — тест не делает колонку нужной продукту.

Неизбирательные узоры не выбрасывайте: печатайте их отдельным предупреждением
рядом со списком — «имена этих колонок могут собираться в коде, посмотрите
глазами», с файлом и строкой.

**Подстановка на месте имени колонки.** `"#{make_goal(g)} in (#{list})"` — такое
место легко не попадает в индекс вовсе: признак «обрывок запроса» обычно требует,
чтобы слева от оператора стояло ИМЯ, а здесь на месте имени сама подстановка.
Разрешите дыру в этой позиции и дайте ей своё место — `column`. Иначе список «не
используется» выносит приговор колонкам, чьё имя в дереве не написано ни разу: у нас
так выглядела вся серия из одиннадцати колонок, которую строит один метод.

**Четыре места, где такой отчёт промахивается мимо, и все четыре в одну сторону —
«не используется» там, где читают.** Каждое у нас стоило ложной строки в ответе:

1. **шаблоны.** Если взятие значения по ключу ищется разбором дерева, а шаблоны
   разбираются построчно, обращений из шаблонов будет НОЛЬ — и это не видно, потому
   что ноль выглядит как «не берут». Собирайте ruby из тегов шаблона (с
   сохранением номеров строк) и ведите по нему тот же разбор. У нас из `.rb`
   приходило 9 249 обращений, из шаблонов — ни одного; после правки 7 180.
   Реализация сборки обязана быть ОДНА на весь индекс: две копии «ruby из шаблона»
   расходятся молча;
2. **начало запроса.** `create table … as select` и `drop table` — тоже запросы, и
   в первом читаются настоящие колонки. У нас запрос на тридцать колонок начинался
   с `drop table if exists` и не разбирался никак;
3. **строка-выражение без интерполяции**: `"paid_until-paid_from<'32 days'::interval"`.
   Ни целым запросом, ни обрывком с дырой она не считается. Пусть решает парсер:
   `select <кусок>` либо разбирается, либо нет. Обязательное условие — в выражении
   есть ОПЕРАЦИЯ, иначе сам список полей (`'a,b,c'`) разберётся как `select a,b,c`
   и объявит использованной каждую колонку списка;
4. **копия таблицы.** Если в схеме живут две копии одних данных, колонку часто
   читают у копии. Формально это другая таблица; честный отчёт говорит «ту же
   колонку читают у <копии>», иначе список выглядит приговором.

**Привяжите строку-ответ к её таблице — иначе `select *` навсегда останется
допущением.** Обращение по ключу знает ИМЯ колонки и не знает, чьей она таблицы, а
вопрос задают всегда про таблицу. Из-за этого `select *` висит над всем отчётом:
строка приходит целиком, из неё могут взять что угодно, и «эту колонку не читают»
становится неизвестным для любой таблицы, которую хоть раз выбирают звездой (у нас
таких 150).

Отсюда соблазн, которому поддаваться нельзя: считать `select *` использованием всех
колонок. Тогда ни одна колонка никогда не окажется неиспользуемой, и отчёт
бесполезен. Обратное решение — считать, что звезда не доказывает ничего — верное, но
это ВЫБОР, а не измерение, и он молча держит на себе весь ответ.

Измеряется он так. Запрос лежит в том же файле, что и чтение, и чаще всего в том же
методе:

```ruby
res = connection.select_all("select * from member_contacts where user_id=#{id}").to_a
res.each do |line|
  email = line['contact']        # ← чтение колонки member_contacts.contact
end
```

Три шага, и все три дешёвые:

1. запоминайте, какие таблицы названы в запросе **по строке файла** — разбор это и
   так посчитал;
2. при присваивании «переменная ← результат запроса» запоминайте строки, где стоит
   этот запрос. И отдельно строки переменной, которая запрос НЕСЁТ: `sql = "select
   * from t"` в одной строке, `res = select_all(sql)` в другой;
3. у цикла по такой переменной привязывайте параметр блока к тому же источнику — и
   возвращайте прежнее значение на выходе из цикла, иначе второй цикл припишет свои
   чтения таблице первого.

Два правила обязательны. **Записывайте чтения ПОСЛЕ обхода, а не по ходу:**
переменную могли наполнить ниже того места, где её читают. И **не придумывайте
владельца, когда запрос назвал две таблицы** — приписать колонку любой из них значит
её выдумать, а по этой записи потом отвечают «поле не используется»: ошибка уедет в
самую опасную сторону.

Что это даёт: обращение по ключу-ПЕРЕМЕННОЙ — ровно то, что звезда прячет, — теперь
тоже знает свою таблицу. Где таких обращений нет ни с этой таблицей, ни с
неизвестной (в тех же файлах), **звезда не прячет ничего**, и «эту колонку не
читают» — факт. У нас это 92 таблицы из 150. И оговорка в отчёте считается по тому
же числу, что и разбивка выше в отчёте: два раздела одной страницы, посчитанные
по-разному, противоречат друг другу на первом же прогоне — у нас так и случилось.

Побочное следствие второй правки стоит знать заранее: **слепых мест станет
больше**. У нас 633 → 731, и девяносто семь из прироста — `create table … partition
of <подстановка>`: до правки такие запросы не разбирались вовсе и в счёт не
попадали. Это переход из молчания в неполноту, то есть именно то, чего и добиваются:
число выросло потому, что инструмент перестал делать вид, что этих запросов нет.

### Слепое место — это весь запрос, а не одна подстановка

И тут стоит остановиться, потому что счёт слепых мест — главная мера собственного
незнания, и к ней легко привыкнуть. У нас дошло до 731, и правильный вопрос был не
«как это объяснить», а «а может, сделать их видимыми?». Разбор состава показал:
слепыми они были не потому, что код непонятен, а **потому что разбор сдавался
слишком рано**. Шесть правил сократили счёт с 731 до 317.

**Разбирайте в несколько подходов, а не в один.** Подстановка `#{…}` заменяется на
`$1`, то есть на ПАРАМЕТР. В позиции значения это верно, а в позиции имени параметр
незаконен — и запрос не разбирается целиком, вместе с таблицами, колонками и целями
записи, которые к этой подстановке отношения не имеют. Ладдер подходов:

1. `$1` — параметр. Годится для значений;
2. `xrefhole` — ИМЯ. Годится для `from #{t}`, `#{col} = 1`. Всё, что содержит
   пометку, отсеивается из фактов: `auth_sid#{i}` даёт
   `auth_sidxrefhole`, и такой таблицы не существует — у неё берётся
   литеральная приставка как догадка;
3. замена ПО МЕСТУ дыры: в условии `true`, в `limit` число, в `set` — `имя=1`, в
   списке определений `create table` — `имя integer`. Место дыры инструмент и так
   вычисляет для отчёта о подстановках, так что это бесплатно.

Три мелочи из того же ряда, каждая по классу находок: дыра ПОСЛЕ готового условия
требует связки (`where x in ($1) $1` → `and true`); литеральное `#{…}` в одинарных
кавычках — тоже дыра, а не мусор (в одинарных кавычках ruby его не раскрывает, и до
разбора он доходит как есть); фраза, начавшаяся с ключевого слова («Select a valid
review status»), запросом не является — отличайте по наличию структуры (`from`,
скобка, запятая, сравнение), а не по первому слову.

**Имя таблицы из переменной ищите по присваиванию.** `from #{table}` — не слепая
зона, если `table = 'queue_journal'` стоит в том же файле: из 137 таких мест у
нас разрешилось 52. Частый узор — выбор из двух (`slow? ? 'a2' : 'a'`): называйте
ОБА имени, а не выражение целиком. И отсевайте по снимку схемы: в
`(group=='GLOM') ? 'users' : 'users_live'` кавычки стоят и у значения условия.

**Отделите «кусок» и «текст» от слепой зоны.** Строка, обрывающаяся на полуслове
(`insert into queue1`), и фраза на человеческом языке — это не «тут запрос, и мы не
знаем какой». Держать их в счёте незнания — врать про себя: у нас это было 140
записей из 731.

**И печатайте категории врозь** в самодиагностике: слепые, разрешённые по
присваиванию, куски. Один общий счёт скрывает, что половина лечится разбором.

Первый из четырёх заслуживает сторожа в самодиагностике: печатайте обращения по
ключу ПОРОЗНЬ — из кода и из шаблонов — и кричите, если из шаблонов пришёл ноль.
Ноль там выглядит как «значение не берут», то есть как разрешение удалить колонку.

И правило, выведенное там же: **доказательство из тестов — не использование в
продукте.** Считайте тесты отдельно и называйте это словами («названа только в
тестах»), иначе один тест молча убирает строку из ответа.

И последнее, самое важное про формулировки: инструмент отвечает **«в коде не
используется»**, а не «можно удалить». Нужны ли данные в поле — вопрос владельца
продукта; ограничение `not null` или наличие данных к вопросу об использовании
отношения не имеют. Смешивать эти ответы — значит отвечать не на то, что спросили.

## IV.12. Что применено в каждой среде

Схемы сред расходятся не сами по себе, и у расхождения почти всегда есть причина в
журнале применённых миграций. Проверка стоит один запрос (`select version from
schema_migrations` в каждой среде) и отвечает на вопрос, который иначе узнаётся в
середине выкатки.

Это ДАННЫЕ, а не схема: в снимке схемы лежат таблицы и колонки, а состав
применённого — содержимое таблицы, и спрашивать его надо отдельно.

Три случая разводите нарочно, иначе отчёт не читают:

1. **в дереве есть, в среде не применено** — риск выкатки, это главная находка;
2. **применено, а файла в дереве нет** — файл удалён или миграция пришла из другой
   ветки;
3. **старые короткие номера** (`15`, `16` — наследство прежних версий фреймворка):
   файлов для них нет и быть не может. Если не отделить, отчёт будет всегда кричать
   о шестнадцати «лишних» миграциях, и его перестанут читать в первый день.

И **сравнение сред между собой**: если боевые среды сошлись, а схемы разошлись —
значит таблицы создавали в обход миграций, и искать надо там. У нас вышло ровно
так.

## IV.13. Ключи окружения: читаем имена, никогда не значения

`ENV['KEY']` при отсутствующем ключе отдаёт `nil` МОЛЧА — ни ошибки, ни строки в
логе. Сверка имён, которые читает код, с именами, которые заданы в среде, — дешёвая
проверка на эту тишину. У нас она нашла, что приём сообщений в одной среде не был
включён никогда.

**Собирайте только ИМЕНА.** Значения — секреты; `sed 's/=.*//'` на узле режет их
до отправки. В индексе значений нет не потому, что их не печатают, а потому, что
их там нет. И менять окружение такой инструмент не должен уметь вовсе.

**Имя ключа бывает НЕ ЛИТЕРАЛОМ.** `ENV[LEASE_SECONDS_KEY]` — такое же чтение,
как `ENV['LEASE_SECONDS']`, но разбор, который умеет только литерал, его не
видит, и отчёт говорит «задано, а в коде не читает никто» про настройку,
которую читают. В чужом проекте так получилось 104 ключа «без читателя», из них
30 с лишним одного семейства; после разрешения констант осталось 75 и 19.
Лечится картой «константа → строка» на файл и подстановкой её в индекс чтения.

Одна тонкость, из-за которой карта бывает пустой: в дереве с
`frozen_string_literal` константу объявляют не литералом, а **вызовом** —
`KEY = 'LEASE_SECONDS'.freeze`. В дереве разбора это узел вызова, а не строки,
и наивный сбор «константа = строковый литерал» не находит ни одной. Снимайте
`.freeze`, `.dup`, `.to_s` с правой части; у нас после этого карта дала 12
констант (и ни одна из них, честно говоря, в `ENV[…]` не подставляется — в
нашем дереве ключи пишут литералом, а проверка всё равно нужна: молчание по
этой причине неотличимо от отсутствия).

**Три разряда, иначе отчёт не читают.** У нас «ключ не задан ни в одной среде» —
это 276 имён; в таком виде список бесполезен. Разряды:

1. **без запасного значения** — придёт `nil`, и это настоящая находка (125);
2. **с запасным значением** (`ENV.fetch('X', 'y')`, `ENV['X'] || 'y'`) — штатная
   настройка, не дыра (138). Запись `||` видна только у родителя: обход идёт
   сверху вниз, и ловить её надо на узле «или», а не на вызове;
3. **читается как ПРИЗНАК** (`if ENV['X']`, `unless ENV['X'].to_i.zero?`) —
   пустое значение там законно и значит «выключено» (13).

**И отделите аргументы задач.** `rake x LIMIT=10` читает тот же `ENV['LIMIT']`, но
в среде такой ключ задавать не надо: у нас таких 370, и без отсева отчёт начинался
с `APPLY`, `LIMIT`, `DAYS`.

**Задан не во всех средах** — отдельный раздел: поведение сред разъезжается, и
причина потом ищется часами.

## IV.14. Тексты: читать хранилище, а не спрашивать библиотеку

Если включены запасные языки (`fallbacks`), то проверка «отдаётся ли перевод»
через библиотеку зелена ВСЕГДА: где перевода нет, молча приедет английский. У нас
так однажды вышло «все 38 ключей отдаются на всех 18 языках» при шестнадцати
непереведённых, и один из них стоял на первом шаге мастера. Поэтому читайте файлы
хранилища сами и считайте ключи по языкам.

Что ловится сверкой «ключи в коде против ключей в хранилище»:

- **ключ зовут, а его нет** — человек увидит «translation missing». Все найденные у
  нас оказались промахом ПРОСТРАНСТВА (`general.refresh` при наличии
  `home.refresh`), поэтому печатайте «есть как»: поиск по последнему звену ключа
  превращает находку в готовую правку;
- **ключа нет на одном из основных языков** — именно они закрывают остальные
  запасными, и пропуск там виден только в сыром хранилище;
- **ключ есть, а не зовёт никто** — текст переводят на восемнадцать языков, а
  показать его нечему.

Четыре тонкости, без которых счёт неверен:

1. **множественные формы — ОДИН ключ.** Если считать `one`/`other` отдельными
   ключами, код зовёт `mail.count`, в хранилище лежат `mail.count.one` и
   `mail.count.other`, и ключ числится отсутствующим. Лист — это хеш, все ключи
   которого суть формы (`zero one two few many other`);
2. **относительный ключ** (`t('.title')`) разрешается ПО МЕСТУ: в шаблоне — по его
   пути, в контроллере — по классу и действию. Без этого половина ключей не
   находится в хранилище никогда;
3. **ключ бывает пространством.** `t('about')` отдаёт хеш, и код обходит его как
   список: такой ключ есть в хранилище как префикс, а не как лист;
4. **собранный ключ закрывает целое пространство.** `t("menu.#{name}")` зовёт всё
   под `menu.`, и объявлять его содержимое осиротевшим — неправда. Но узор обязан
   быть ИЗБИРАТЕЛЬНЫМ: узор из одной подстановки совпадает с любым ключом и
   объясняет сразу всё, то есть ничего. У нас порог — четыре буквы литеральной
   части, и он снял три тысячи ложных «сирот», оставив три тысячи настоящих.

И печатайте «сирот» **по файлам**, а не по именам: три тысячи имён читать никто не
станет, а «в этом файле 1 370 ненужных ключей» — уже решение.

## IV.15. Выполненные запросы: четвёртый уровень доказательства

Самая крупная слепая зона статического разбора — имя, собранное интерполяцией
(`shard_table#{i}`). Статически известно только «чем собрано имя». Лог приложения
пишет уже РАЗРЕШЁННОЕ имя, и это единственный источник, который эту зону закрывает,
а не описывает.

Механика та же, что у логов отрисовок: разбор НА УЗЛЕ, обратно едет сводка. Но два
правила тут жёстче.

**Значения не покидают узел, и нормализация стоит ПЕРВОЙ.** Боевой SQL — это
адреса, ключи, тексты писем. Скрипт на узле первым делом заменяет литералы:
строки на `'x'`, числа на `1`. Наружу едет узор и счётчик. В индексе значений нет
и быть не может — не «мы их не печатаем», а их там нет.

**Числа внутри ИМЁН не трогайте.** `queue2`, `sessions3`, `shard_table4` —
это ровно те имена, ради которых всё и делается. Замена «любого числа» уничтожает
их: подставляйте только там, где перед числом стоит не буква и не подчёркивание.

```sh
sed -e "s/E'[^']*'/'x'/g" -e "s/'[^']*'/'x'/g" \
    -e 's/\([^A-Za-z0-9_$]\)[0-9][0-9.]*/\1 1/g' \
    -e "s/'x'\( *, *'x'\)\+/'x'/g" -e 's/\( 1\)\( *, *1\)\+/ 1/g' \
| cut -c1-1500 | sort | uniq -c | sort -rn
```

Узор режется — иначе поедут километровые запросы, — но **коротко резать нельзя**:
список полей в бою это шесть десятков имён и девять сотен символов, и при обрезке в
400 колонки из хвоста выглядели «в бою не тронутыми». Сколько узоров не разобралось
из-за обрезки, печатайте рядом с выводом.

**И самое важное, что обнаруживается сразу: колонка в УСЛОВИИ — это не то же, что
колонка в списке вывода.** В бою запрос выбирает список полей целиком, поэтому
«названа в выборке» значит ровно то же, что имя в списке полей: ничего. А колонка в
`where`/`order by`/`set` работает — по ней отбирают строки. Разряд берётся из ПУТИ
узла в дереве разбора (`[:stmts, 0, :stmt, :select_stmt, :where_clause, …]`), а не
обходом поддерева руками: узлы отдают детей хешами, и ссылка на узел теряется.
Считайте этот разряд и статически, и по логам — и тогда ответ «поле не
используется» можно проверить вторым способом, который про код ничего не знает: у
нас из двадцати шести таких колонок в боевых логах встретились пять, и все пять
только в списке вывода.

### Второй источник того же знания: статистика самой базы

У логов есть один недостаток, и он не лечится аккуратностью: **окно**. Лог живёт
сутками и ротируется, поэтому недельный крон, месячный отчёт и редкий экран в
суточное окно не попадают вовсе. Копить логи самому — значит копить то, что база
уже копит за вас: сборщик статистики запросов (у нас это pg_profile) хранит
снимки `pg_stat_statements` историей. На одном нашем источнике это **336 снимков
за восемь суток** там, где логов было за двое, и это дало **67 таблиц, которых
индекс не видел ни в логах, ни в разборе**.

Это не противоречит правилу «не включайте в бою тяжёлую диагностику ради
инструмента анализа» (часть IX): включать ничего не надо — надо **спросить то,
что в бою уже собирают**. Если не собирают, остаются логи.

Правила ровно те же, что у логов, и формулировка нормализации тоже — только
выражена она в SQL и выполняется НА УЗЛЕ:

```sql
with win as (   -- окно: снимки нужного сервера за N суток
  select s.sample_id, s.server_id, s.sample_time::date as day
  from profile.samples s
  join profile.servers v on v.server_id = s.server_id and v.server_name = 'local'
  where s.sample_time >= current_date - 30
),
app as (        -- только база приложения: в статистике лежат все базы сервера
  select distinct d.sample_id, d.datid
  from profile.sample_stat_database d where d.datname = 'имя_базы'
)
select w.day, sum(st.calls) as hits,
       left(regexp_replace(
              regexp_replace(
                regexp_replace(
                  regexp_replace(l.query, '''[^'']*''', '''x''', 'g'),
                '([^A-Za-z0-9_$])[0-9][0-9.]*', '\1 1', 'g'),
              '''x''( *, *''x'')+', '''x''', 'g'),
            '\s+', ' ', 'g'), 1500) as skeleton
from profile.sample_statements st
join win w on w.sample_id = st.sample_id and w.server_id = st.server_id
join app a on a.sample_id = st.sample_id and a.datid = st.datid
join profile.stmt_list l on l.server_id = st.server_id and l.queryid_md5 = st.queryid_md5
-- Только операторы данных: в статистике лежат и `SAVEPOINT $1`, и
-- `SET application_name = $1` — миллионы вызовов, из которых про дерево не
-- узнать ничего.
where l.query ~* '^[[:space:]]*(select|insert|update|delete|with)[[:space:]]'
group by 1, 3 having sum(st.calls) > 0
```

Четыре тонкости, каждая у нас уже стоила неверного ответа:

1. **Нормализация всё равно нужна, хотя текст уже без литералов.** В
   `pg_stat_statements` параметры заменены на `$1` самой базой — но не у всех
   операторов: часть постгрес не параметризует. Полагаться на «там и так нет
   значений» нельзя, правило «значения не покидают узел» остаётся в силе.
2. **`ON_ERROR_STOP=1` — не придирка.** Без него клиент базы на ошибке в
   запросе выходит НУЛЁМ, вывод пустой, и отчёт честно печатает «узоров 0».
   Поймано на первом прогоне: группировка по позиции в склеенной строке была
   неверна, а выглядело это как «в статистике ничего про нас нет».
3. **Обрезка узора — по пробелу, а не по знаку.** Срез посреди имени выдумывает
   таблицу: `… from big_users` обрезанное по 1500 дало `big_`, и это имя уехало
   в «таблица, которой нет ни в одной схеме». Правило общее с логами.
4. **Окно надо спрашивать у источника и печатать.** Сколько снимков и за какие
   даты база помнит — отдельный запрос (`min/max(sample_time)`), и он обязан
   стоять рядом с ответом: «в бою не трогали» за двое суток и за восемь — разные
   утверждения, а выглядят одинаково.

И честная граница: настроен такой сбор у нас пока на ОДНОМ источнике из трёх.
Поэтому окно у ответов разное по источникам, и отчёт печатает его по каждому
отдельно — одно общее число тут было бы ложью.

## IV.16. Заполненность колонок: третий уровень доказательства

Код и схема отвечают только половину вопроса «можно ли удалить колонку». **«Код не
читает» и «в колонке ничего нет» — разные утверждения**, и решение требует обоих.
Третий сбор — сплошной проход по живым данным: сколько строк заполнено, сколько
отличается от умолчания, сколько заполнено у свежей когорты.

Три ловушки. Каждая из них один раз испортила замер, когда он считался руками:

**Умолчание.** При `default 1` колонка, которой никто никогда не трогал, по счёту
«не ноль» заполнена у всех до единого. Значимо другое — сколько строк **отличается
от умолчания**. У одной нашей колонки это 17 строк из 3,38 млн: по первому счёту
она «живая», по второму — пустышка. У соседней, наоборот, 208 353 человека
поставили не умолчание (выключили уведомление), а код эту колонку не читает нигде —
то есть выбор людей молча игнорируется. Ни один из этих двух выводов не получается
без сравнения с умолчанием.

NULL из счёта «не по умолчанию» исключайте: вопрос «сколько людей поставили не то,
что ставится само», а пустое значение на него не отвечает. Без этого у колонки с
умолчанием и миллионом NULL «не по умолчанию» выходит больше, чем «заполнено», и
число читается как бессмыслица.

**Тип.** Условие «есть значение» зависит от типа, и ошибка тут не косметическая:
`boolean <> 0` — ошибка базы, которая валит ВЕСЬ запрос, и таблица остаётся без
замера вовсе (а не «с нулями»). Текст сравнивается с пустой строкой, дата — только
с NULL, логический тип — сам собой.

Два следствия, которые видны только на большом прогоне, и оба мы получили:

- **список числовых типов должен быть БЕЛЫМ, а не чёрным.** Пока условие
  `<> 0` ставилось всем, кто «не текст и не дата», на него попал
  `interval` — и один столбец длительности (`span_length`) уронил запрос по
  своей таблице;
- **неудача одной таблицы не должна валить прогон.** Та же ошибка в первом
  заходе прервала батч из 24 таблиц целиком: замера не получила ни одна, а
  причина была в одной. Ошибку ловите на таблице, запоминайте её текст рядом с
  результатом и идите дальше — иначе цена одного неизвестного типа равна цене
  всего прогона.

**Свежесть.** Общий счёт не отличает умершую механику от живой. У одной колонки
141 006 заполнений всего и **одно** у тех, кто зарегистрировался за последний год.
Вторая мера — доля у свежей когорты; если она в десять раз ниже общей, механика
угасает. Колонку когорты берите по имени из короткого списка кандидатов и
сравнивайте правильно: эпоха числом и настоящая дата требуют разных условий.

```ruby
# Одна таблица — ОДИН проход: три счётчика на колонку в одном select.
parts = ['count(*)', recent ? "count(*) filter (where #{recent_cond})" : 'null::bigint']
columns.each do |name, type, default|
  filled = filled_condition(name, type)          # по типу, иначе запрос падает
  parts << "count(*) filter (where #{filled})"
  parts << (default.present? ? "count(*) filter (where #{off_default(name, default)})" : 'null::bigint')
  parts << (recent_cond ? "count(*) filter (where #{recent_cond} and #{filled})" : 'null::bigint')
end
```

Выборки не делайте: доли, посчитанные по выборке, у нас однажды завысили беду в
семьсот раз. Проход сплошной — 3,4 млн строк и 99 колонок это 53 секунды, — и
именно поэтому он НЕ входит в обычное обновление индекса: полное чтение боевой
таблицы запускает человек, а не догон.

И печатайте ПОКРЫТИЕ этого замера рядом с ответами, которые на него опираются:
у нас измерено 28 таблиц (820 колонок) из восьмисот с лишним, то есть три
процента. Это самая честная мера того, сколько ещё не знаем, — и она же
объясняет, почему «колонку никто не читает и данных в ней нет» остаётся
утверждением про измеренные таблицы, а не про базу.

Рядом снимайте **сканирования индексов** из статистики базы. Индекс, в который
никто не заглянул, — не «лишнее поле», но цена у него та же: место и работа при
каждой записи (у одной нашей пары таблиц 38 неиспользуемых индексов на 551 МБ).
Храните вместе с датой обнуления счётчиков: перезапуск базы их сбрасывает, и без
этой даты «ноль сканирований» не значит ничего.

## IV.17. Две проверки, которые ловят поломку, а не неиспользуемое

Обе появились из попытки ответить на вопрос «какие поля лишние» — и нашли не
лишнее, а сломанное.

**Код обращается к колонке, которой в таблице нет ни в одной среде.** Для таблиц
такая проверка обычно есть; для колонок её забывают. У нас первый же прогон нашёл
**пять боевых запросов, которые не могут исполниться**, и у трёх ошибка — промах на
одно слово (`last_added` вместо `added_at_time`, `creation_time` вместо
`created_data`). Поэтому печатайте подсказку «похоже на»: близкое имя из той же
таблицы превращает отчёт в готовую правку.

Чтобы такая проверка не врала, разбор колонок обязан различать три случая, иначе
она придумывает колонки, которых нет:

- **звезда с определителем.** `select u.*` — это звезда у `u`, а не колонка с
  именем `u`: строковое поле у такой ссылки одно, и оно уезжает в колонки;
- **подзапрос в `from`.** В `select b from (select … as b from t) x` колонка `b`
  принадлежит подзапросу. Привязывать безымянную колонку к единственной таблице
  запроса можно только когда производных таблиц нет;
- **псевдоним вычисления.** `select abs(a - b) as abs … order by abs` — здесь `abs`
  имя столбца вывода. Запись не выбрасывайте (имя псевдонима может совпасть с
  настоящей колонкой, и терять чтение нельзя) — не придумывайте ВЛАДЕЛЬЦА. И
  ограничьте правило списком вывода `select`: у `update t set c = c + 1` цель это
  тоже «имя с выражением», и без ограничения чтение `c` справа теряет владельца.
  Нас на этом поймала собственная спека.

**Дефекты списков полей.** Если список колонок собирается в одном месте и
подставляется в запрос целиком, его состав — такой же предмет проверки, как код:

- **повтор имени** внутри списка. Дедупликация при разборе состава правильна, но
  сам факт повтора надо запомнить — иначе проверить это механически нечем;
- **пропуск в числовой серии.** Если в списке есть `opt4_1…opt4_4` и `opt4_6`, а у таблицы
  есть и `opt4_5`, которого в списке нет, — это почти всегда опечатка. У нас повтор и
  пропуск оказались одной и той же опечаткой: одно имя заняло место другого, и
  колонка у 19 452 человек заполнена, но не читается никем. Человек нашёл это
  глазами; проверка находит за секунду.

Привязывайте список к таблице по составу имён (доля совпавших) и отсевайте шум,
выведенный из НАСТОЯЩЕГО шума, а не придуманный заранее: у нас это чисто числовые
и односимвольные «имена» (в дереве есть таблица с колонками `1`…`33` и другая с
`a`…`t`) и списки, уверенно не привязанные ни к одной таблице. Счётчики обеих
проверок печатайте в самодиагностике: отсев подогнан под сегодняшнее дерево, и если
число прыгнуло, сначала надо смотреть на разборщик, а не на код.

## Слои за пределами кода: документы, настройки, скрипты, конфигурация фронта

Эту главу стоит прочесть прежде, чем решать, где у индекса граница. У нас она
долго проходила по расширению файла: разбирались `.rb`, `.erb`, `.js`, `.sql` —
**8 291 файл из 23 337**. Про остальные 15 тысяч индекс молчал, и молчание
читалось как «там ничего нет». А там было вот что.

**Документация — такой же источник утверждений о дереве, как код, и стареет она
молча.** У нас 12 243 файла `.md`. Ссылка на снятый файл выглядит как ссылка;
имя удалённой таблицы читается как действующее. Разбор даёт заголовки (разделы —
чтобы ответ указывал место, а не только файл), ссылки, упоминания путей и
**блоки кода, разобранные теми же разборщиками, что файлы**: запрос в документе,
который не разбирается, — это пример, который никто не проверял.

Два правила, без которых этот слой приносит вред:

1. **Вид записи отдельный.** Упоминание таблицы в документе — НЕ обращение к
   таблице. Смешать их значит объявить используемым то, о чём просто написано, и
   отравить главный ответ инструмента.
2. **Слова прозы в индекс не идут.** Имя считается названным только в обратных
   кавычках или в блоке кода. Иначе 157 МБ документов утопят ответы в
   совпадениях вида «в таблице ниже».

**И главная опасность этого слоя — ЛОЖНАЯ ТРЕВОГА.** Первый прогон дал 137
«сломанных примеров кода». Проверка глазами: настоящих четырнадцать. Остальное —
разряды, которые дефектами не являются и должны быть названы по именам:

| разряд | признак | почему не дефект |
| --- | --- | --- |
| набросок | `…`, `<номер ДЦ>`, `<email>` | человеческий пропуск, и не должен исполняться |
| отрывок | обрыв посреди `if`/`when`/`end` | цитата кода, а не код |
| заплатка | строки на `-`/`+` | это diff |
| кусок запроса | начинается с `from`/`where` | достраивается приставкой и разбирается |
| шаблон | `:имя`, `?`, `@TOOL@` | подстановка, а не ошибка |
| другой диалект | обратные кавычки, `MergeTree`, `CODEC` | валидный SQL другого движка |
| метка врёт | в блоке `ruby` лежит SQL | верить СОДЕРЖИМОМУ, а не метке |

То же с ссылками: из 632 «битых» 617 оказались абсолютными путями в рабочий
каталог, которого в чужой копии дерева не бывает вовсе. Настоящих 15. **Если
разряды не разделить, инструмент выдаёт шесть сотен находок при пятнадцати — и
перестаёт быть инструментом.**

Что находится по делу: **1 346 путей, названных в документах и не существующих в
дереве** (у нас один каталог видов поминают 18 документов, а каталога нет),
таблицы из запросов в документах, которых нет ни в одном снимке схемы, и
примеры, не разбирающиеся ни одним способом.

**Настройки: главное в них — не ключи, а ERB.** В `.yml` через ERB читается
окружение (`database.yml`, `cable.yml`, `storage.yml`), и пока yaml не
разбирался, эти чтения были невидимы, а отчёт при этом утверждал «в коде не
читают». Разбор двухслойный: сначала ruby из ERB-тегов (его ведёт ТОТ ЖЕ обход,
что файлы ruby — отдельной ветки быть не должно), потом дерево ключей по тексту,
из которого ERB вырезан пометкой (не пустотой: `host: <%= … %>` без значения
перестаёт быть парой).

**Значений настройки в индексе нет и быть не может** — это пароль, адрес или
ключ. Записываются только имена. И глубину ограничивайте: описи прежних задач
дали у нас 42 945 записей из 593 файлов, двадцать тысяч имён вида
`rows.0.status_semantics`, на которые никто никогда не спросит.

**Скрипты оболочки: одно различение решает всё.** Ключ среды, прочитанный
скриптом, — такое же чтение, как из ruby, и heredoc с запросом разбирается тем
же разборщиком SQL. Но `$sha`, `$img`, `$path`, `$attempt` — это переменные
скрипта, и их больше, чем настоящих ключей: без различения в «ключи окружения»
попадало **111 имён из 442**. Признак двойной:

* имя, которое скрипт ПРИСВАИВАЕТ, — своё. Присваивание бывает и без знака
  равенства: в цикле (`for host in …`), при чтении строки (`read -r line`), при
  объявлении (`local tmp=`). Исключение одно и идиоматическое:
  `VAR=${VAR:-умолчание}` и присваивает, и читает среду;
* **регистр**: ключ среды пишется заглавными. Присваивание ловится не всегда —
  имя может получать значение внутри heredoc, который целиком уезжает на узел.

Отдача: у нас **133 ключа читают только скрипты**, и до разбора `.sh` этих имён
не было в отчёте ни в одном разряде — а про часть утверждалось «в коде не
читают», что было прямой неправдой.

**Конфигурация фронта — самый дорогой разбор из этих четырёх**, потому что
ошибка в ней НЕ ПАДАЕТ: фронт тихо начинает отдавать не то. Четыре правила, и
каждое у нас уже стоило происшествия: незаякоренная регулярка вхоста (съела два
боевых адреса), `rewrite … last` (выбор локации начинается заново, и сторожа
своей локации не применяются), `http_404` в списке причин перехода к следующему
узлу (каждый честный 404 умножается на число узлов), свой `add_header
Cache-Control` без `proxy_hide_header` (чужой заголовок не заменяется).

И здесь же — второй урок про ложную тревогу. Первый вариант правила про
`rewrite … last` дал 25 находок. Но `rewrite … last` сам по себе НОРМА и
единственный способ переписать путь; беда начинается только там, где в ТОЙ ЖЕ
локации стоит `limit_conn` или `add_header`. С этим условием находок две — и
вторая ровно тот случай, что уже случался в бою.

**Javascript: разбирать стоит не язык, а СВЯЗКУ с разметкой.** Полного парсера
javascript у нас нет и не нужно. Ценность даёт другое: модульные рёбра
(`require`/`import` — не забудьте оба, у нас 102 файла на одном и 12 на другом) и
связка «разметка → контроллер → его метод», потому что контроллер вызывает не
код, а атрибут в шаблоне, и никакой граф импортов этого не покажет.

Четыре правила, без которых этот слой даёт ложные находки:

1. **Реестр — единственная власть.** Имя в атрибуте значит что-нибудь только
   если оно зарегистрировано (`application.register('имя', Класс)`). Без этой
   проверки чужие атрибуты вида `data-bs-target` (Bootstrap) идут в находки — у
   нас это было 70 мест.
2. **Корни сборки — точки входа, а не мёртвые файлы.** Их не импортирует никто
   по построению: сборщик начинает с них. Пока они не названы входами, весь
   javascript лежит вне графа достижимости, а сами они числятся недостижимыми.
   Там же живут самостоятельные скрипты и файлы, названные в командах сборки
   (`package.json`): у нас после разделения по разрядам мёртвых файлов осталось
   НОЛЬ из 248 «недостижимых».
3. **Объявление бывает в трёх видах** (`static targets = […]`, то же в несколько
   строк, `static get targets() { return […] }`), и пропуск любого даёт ложное
   «цель не объявлена»: у нас геттером объявляют семь контроллеров из двадцати
   одного.

4. **Включений ТРИ вида, не один.** Контроллер включает разметка шаблона, но
   также помощник на бэкенде (`'data-controller' => 'имя'`, `data: { controller:
   'имя' }`) и код на ходу (`el.dataset.controller = 'имя'`,
   `setAttribute('data-controller', …)`). Пока разбор смотрел только на HTML,
   «не включает никто» было сказано про три контроллера, из которых таков один.
   Короткий ключ `controller:` при этом годится ТОЛЬКО внутри хеша `data:` — вне
   его это маршрутизация, и таких мест у нас 265.

Что проверяется на этой связке и чего без неё не узнать: действие, указывающее
на несуществующий метод (не падает — просто не происходит ничего), шаблон с
незарегистрированным контроллером (Stimulus молча пропускает неизвестное имя),
цель, которой контроллер не объявлял, значение без умолчания, которого разметка
не задаёт, и контроллер, которого не включает ни один шаблон.

**Итог по границе.** После семи разборов индекс видит 21 585 файлов из 23 411
(92 %). Не разбираются: картинки, шрифты, `node_modules` и `vendor`. И это уже
не молчание, а названный список. Два последних слоя — таблицы стилей и функции
javascript — вынесены в IV.18 и IV.19: у каждого своя ловушка, и обе дают
находки в опасную сторону «можно выкинуть».

## IV.18. Таблицы стилей: объявлено, подключено, применяется в контуре

Слой, который заводят последним, а спрашивают первым: «какие стили не нужны».
Отвечать на него без разбора нечем — но отвечать на него НЕВЕРНО легче, чем в
любом другом слое, потому что имя класса собирают на ходу чаще, чем имя таблицы.
Поэтому порядок такой: сперва мера незнания, потом находки.

**Разбирайте ЧАСТИЧНО, и это решение, а не экономия.** Нужны ровно три вещи:
какие классы объявлены, какие файлы подключают друг друга и какие классы
поминает сам стиль (`@apply`). Значения свойств, переменные, примеси и
медиа-условия не нужны: по ним вопросов не задают, а разбор каскада и
специфичности — это уже свой браузер. У нас весь разборщик стилей — 134 строки.

**Две ловушки SCSS, и каждая врёт в сторону «класс не объявлен».**

```ruby
# `&-big` внутри `.btn` объявляет `.btn-big` — такого имени в файле НЕТ целиком.
# Не собрав его, отчёт назовёт `btn-big` необъявленным там, где правило есть.
def selector_names(selector, parent)
  names = []
  selector.to_s.split(',').each do |part|
    part = part.strip
    next if part.empty?

    if part.start_with?('&')
      suffix = part[/\A&([-_A-Za-z0-9]*)/, 1].to_s
      Array(parent).each { |base| names << (suffix.empty? ? base : "#{base}#{suffix}") }
      # `&.active` и `& .inner` объявляют и свои классы тоже.
      names.concat(part.sub(/&([-_A-Za-z0-9]*)/, ' ').scan(/\.(-?[A-Za-z_][A-Za-z0-9_-]*)/).flatten)
    else
      names.concat(part.scan(/\.(-?[A-Za-z_][A-Za-z0-9_-]*)/).flatten)
    end
  end
  names.uniq
end
```

Вторая — **частичный файл**: `@import 'base/reset'` ведёт в `_base/_reset.scss`,
то есть в имя с подчёркиванием, которого в ссылке нет. Без этого правила каждый
такой импорт «ведёт в никуда», а цель числится никому не нужной.

**И третья, не из SCSS: ссылка на ПАКЕТ — не битая ссылка.**
`@import 'tailwindcss'`, `@import 'bootstrap/dist/css/bootstrap.css'` — это
node_modules, а не путь в дереве. Пока они шли в «ведёт в никуда», отчёт называл
битыми одиннадцать живых строк сборки; настоящих было ноль. Признак:
неотносительный путь плюс существующий каталог пакета.

**Чем файл стилей бывает жив — ЧЕТЫРЕ дороги, и пропуск любой даёт мёртвый
живой файл.** У нас первый прогон сказал «четыре таблицы стилей не подключает
никто»; настоящая одна:

| дорога | как выглядит |
| --- | --- |
| `@import` из другого стиля | обычное ребро между файлами |
| вход сборки | назван в конфиге бандлера (`entryPoints`) |
| **импорт из javascript** | `import '../css/uppy_upload.css'` в корне пака — сборщик отдаёт css побочным выходом |
| **путь, собранный в конфиге** | `path.join(root, 'app', 'javascript', 'x', 'x.css')` — ключа с именем у входа нет вовсе |

**Потребитель класса — тоже четыре дороги**: литерал в разметке
(`class=`/`className=`), помощник на бэкенде (`class: 'btn'`), код на ходу
(`classList.add`, `addClass`, `toggleClass`) и атрибуты Stimulus
(`data-…-class`). И одно правило порядка, на котором я уже ошибся:

```ruby
def note_class_list(text, line)
  # ПОРЯДОК РЕШАЕТ: сперва маскируем подстановки, потом режем по пробелам.
  # Наоборот `class="btn btn-<%= kind %>"` рассыпается на `<%=`, `kind`, `%>`,
  # и `kind` попадает в индекс КЛАССОМ, которого в стилях нет вовсе.
  masked = text.to_s.gsub(/<%.*?%>/m, '$1').gsub(/\#\{[^}]*\}/, '$1')
  masked.split(/\s+/).reject(&:empty?).each do |word|
    if !word.include?('$1')
      add('html_class', word, '', line) if word.match?(/\A-?[A-Za-z_][A-Za-z0-9_-]*\z/)
    elsif word.delete('$1').match?(/[A-Za-z0-9]{2}/)
      add('html_class_pattern', word, '', line, detail: { glob: like_pattern(word) })
    else
      add('html_class_dynamic', text.to_s.strip, '', line)   # честная слепота слоя
    end
  end
end
```

**Мера незнания печатается первой строкой раздела.** У нас это **2 421 место,
где имя класса собрано ЦЕЛИКОМ**, и 287 узоров. Две тысячи таких мест означают,
что список «класс не поминает никто» — нижняя граница, а не приговор. Плюс
стили из `node_modules` не читаются вовсе, поэтому класс библиотеки всегда
попадёт в разряд «правила нет ни в одном НАШЕМ стиле».

**Главный вопрос слоя — не «мёртв ли класс», а «есть ли правило В ЭТОМ
КОНТУРЕ».** Класс бывает жив в одном дереве шаблонов и не делает ничего в
другом, и это не смерть, а недоезд стиля. Цепочка: **контур → имя пака из
макета → вход сборки → `@import` → файл**. Три тонкости:

- **контур берите только ДОКАЗУЕМЫЙ** — тот, у которого макет своего имени
  называет пак. Каталог шаблонов контуром не является: он рисуется под макетом,
  который выбирается на ходу. Мой первый вариант выдумал пять таких «контуров»
  и уверенно разложил по ним стили;
- **имя пака у собранного входа берётся по СОГЛАШЕНИЮ ИМЁН** (имя файла без
  расширения), и это надо сказать вслух. Пока связи не было, у контура не
  оказывалось ни одного своего стиля, и вид отвечал «правила в контуре нет» на
  все 632 класса — честно и бесполезно;
- **рядом с именем печатайте файл правила.** `gap-2` → «правило в
  `css/utils.css`» значит «наш шим утилит в этом контуре не подключён»,
  и это другое решение, чем «класс мёртв».

Что этот слой нашёл у нас: одну таблицу стилей, которую не подключает никто
(44 байта), 569 объявленных классов без единого упоминания — и видно их **по
файлам**, потому что решение принимается по файлу: шим совместимости, переживший
свою нужду, выдаёт себя долей (`theme_compat.css` — 34 имени из 95,
`css3-icon.css` — 87 из 151). И 207 классов одного контура, чьё правило лежит в
другом: каждый — либо недоезд стиля, либо лишний класс в разметке.

## IV.19. Функции javascript и библиотеки: вызовы считаем, внутрь не лезем

Продолжение связки из предыдущей главы, но вопрос другой: не «работает ли
контроллер», а «что здесь можно выкинуть». Ответ дорогой: первый прогон дал
**357 мёртвых функций**, настоящих в приложении — **ноль**.

**Объявление в трёх формах** (`function имя`, `const имя = (…) =>`,
`window.имя = function`), и у каждой есть ловушка: голова объявления сама
совпадает с образцом вызова. Не отсекая её, у каждой объявленной функции
находится «вызов» из собственной строки — и мёртвых не бывает НИКОГДА.

**Маскируйте не-код прежде, чем искать вызовы.** Строки, регулярки и шаблонные
строки дают ложные вызовы, и дальше всё читается как находка о дереве:

```ruby
masked = row.gsub(/'(?:\\.|[^'\\])*'/, "''").gsub(/"(?:\\.|[^"\\])*"/, '""')
            .gsub(%r{(?<=[=(,:\[!&|?+\s])/(?:\\.|[^/\\\n])+/[gimsuy]*}, '//')
# Шаблонная строка маскируется, а подстановки из неё СОХРАНЯЮТСЯ: в `${build(x)}`
# вызов настоящий, а текст вокруг — нет.
masked = masked.gsub(/`(?:\\.|[^`\\])*`/) { |span| span.scan(/\$\{[^}]*\}/).join(' ') }
```

У нас именно здесь жила находка «дерево зовёт lodash глобалом»: `_(` стояло
внутри регулярки `/^(?:letdiv)_\d+_(\d+)$/` и внутри шаблонной строки. Проверка
у первоисточника: не зовёт.

**`...fn()` — расширение, а не обращение к методу.** Образец вызова обычно
отсекает всё, перед чем стоит точка, — и тогда вызов после спреда теряется, а
функция числится мёртвой:

```ruby
CALL = /(?:(?<![.\w$])|(?<=\.\.\.))(?<name>[A-Za-z_$][\w$]*)\s*\(/
```

**И главное: «никто не зовёт по имени» — это НЕ смерть функции.** Путь от 357 к
нулю показателен, потому что каждый шаг снимал свой способ быть живым:

| шаг | осталось |
| --- | ---: |
| нет вызова `имя(` | 357 |
| имя нигде не поминается (просев поиском по тексту) | 13 |
| искать по ВСЕМУ дереву, а не только в каталоге приложения | 6 |
| разряд по месту: одноразовый скрипт против приложения | **0 в приложении** |

Функцию передают значением (`setTimeout(tick)`, `{ install: fn }`), экспортируют
(её может звать другой файл), зовут из скрипта вне приложения. Поэтому вызов по
имени записывайте **зацепкой, а не фактом**, и печатайте это словами — ровно как
с именами в ruby.

**Библиотеки: внутрь не лезьте.** Внутри библиотеки «неиспользуемого»
большинство по построению, и выкидывают её версией, а не правилами. Считать надо
другое — **привязки импорта** и упоминания привязки в теле файла: пакет, чью
привязку не поминают нигде, это мёртвая зависимость, и такой ответ полезен.
У нас таких ноль из двенадцати.

Отдельной строкой — **доступ ГЛОБАЛОМ, без импорта**: это и есть вопрос «можно
ли выкинуть jQuery». Он решается не графом импортов, а поиском `$(` по
javascript приложения — и в нашем дереве его там нет ни одного раза (четыре
совпадения — комментарий и три строки ruby).

**Файл, которого не импортирует никто, бывает жив по пяти причинам**, и без
разрядов они все читаются как кандидаты на снятие: корень сборки, самостоятельный
скрипт, объявление типов (`.d.ts` — его читает только компилятор), прогон тестов
(`*.test.ts`), настройка сборки (`*.config.js`). В чужом проекте последние три
дали восемь ложных кандидатов, среди которых потерялся бы настоящий.

---

# Часть V. Представления

Отчёты пишутся по этим представлениям, а не по таблицам напрямую. Приведены те,
где логика неочевидна.

**Последний удавшийся снимок каждого источника** — основа всего остального:

```sql
create view v_current as
select distinct on (s.source_id)
       s.id as snapshot_id, s.source_id, src.name as source, src.kind as source_kind,
       s.taken_at, s.git_sha, s.server_version, s.database_name
from snapshots s
join sources src on src.id = s.source_id
where s.ok
order by s.source_id, s.taken_at desc, s.id desc;

-- Реляционная база и колоночная живут в одних таблицах снимков, но в РАЗНЫХ
-- пространствах имён: одно и то же имя там и там — разные вещи.
create view v_tables as
select c.source, t.name, t.kind, t.est_rows
from db_tables t join v_current c on c.snapshot_id = t.snapshot_id
where c.source_kind = 'pg';

create view v_columns as
select c.source, col.table_name, col.column_name, col.ordinal,
       col.data_type, col.not_null, col.default_expr
from db_columns col join v_current c on c.snapshot_id = col.snapshot_id
where c.source_kind = 'pg';
```

**Где таблица есть и где её нет.** `missing_in` считается только по источникам
того же вида:

```sql
create view v_table_presence as
select g.name, g.present_in,
       array(select s.source from v_current s
             where s.source_kind = 'pg' and not (s.source = any(g.present_in))
             order by 1) as missing_in
from (select name, array_agg(source order by source) as present_in
      from v_tables group by name) g;

create view v_column_presence as
select g.table_name, g.column_name, g.present_in, g.types, g.types_by_source,
       array(select s.source from v_current s
             where s.source_kind = 'pg' and not (s.source = any(g.present_in))
             order by 1) as missing_in
from (select table_name, column_name,
             array_agg(source order by source) as present_in,
             array_agg(distinct data_type) as types,
             array_agg(source || ':' || data_type order by source) as types_by_source
      from v_columns group by table_name, column_name) g;

-- Колонка есть не везде — но только у таблиц, которые есть ВЕЗДЕ. Иначе отчёт
-- тонет в колонках резервных таблиц одной среды.
create view v_column_drift as
select cp.* from v_column_presence cp
join v_table_presence tp on tp.name = cp.table_name
where cardinality(cp.missing_in) > 0 and cardinality(tp.missing_in) = 0;
```

**Рёбра графа.** Ссылка на константу — только один их сорт; сама по себе она
оставляет вне графа все шаблоны и все связи моделей.

```sql
create view v_const_edges as
select r.path as from_path, r.owner as scope, c.path as to_path, 'const' as kind
from code_refs r
join app_constants c on c.constant = r.token
where r.kind = 'const_ref' and c.path <> r.path;

-- Имя шаблона в коде ведёт во ВСЕ варианты интерфейса сразу: логическое имя у
-- них общее, файлы разные. Суффикс сравниваем через right(), а не LIKE: в именах
-- шаблонов сплошные подчёркивания, а для LIKE это подстановочный знак.
create view v_render_edges as
select r.path as from_path, '' as scope, v.path as to_path, 'render' as kind
from code_refs r
join code_refs v
  on v.kind = 'view_name'
 and (v.token = r.token or right(v.token, length(r.token) + 1) = '/' || r.token)
where r.kind = 'render_ref' and v.path <> r.path;

-- Ребро-КАНДИДАТ: имя дособирается на ходу, но узор из литеральных кусков есть.
-- Экранирование тильдой — по той же причине.
create view v_render_candidate_edges as
select r.path as from_path, '' as scope, v.path as to_path, 'render?' as kind
from code_refs r
join code_refs v
  on v.kind = 'view_name'
 and (v.token like (r.detail->>'glob') escape '~'
      or v.token like ('%/' || (r.detail->>'glob')) escape '~')
where r.kind = 'render_dynamic' and r.owner = 'skeleton'
  and r.detail->>'glob' is not null and v.path <> r.path;

-- Контроллер рисует шаблон ПО ИМЕНИ ДЕЙСТВИЯ, без всякого вызова отрисовки.
-- Без этого ребра шаблоны висят отдельным островом вообще без точек входа.
create view v_action_view_edges as
select c.path as from_path, '' as scope, v.path as to_path, 'action' as kind
from app_routes r
join app_controllers c on c.class_name = r.controller_class and c.path is not null
join code_refs v
  on v.kind = 'view_name'
 and (v.token = r.controller || '/' || r.action
      or right(v.token, length(r.controller) + length(r.action) + 2)
         = '/' || r.controller || '/' || r.action)
where r.controller <> '' and r.action <> '';

-- Связь модели — тоже ребро: объявленная связь ведёт в класс на другом конце.
create view v_assoc_edges as
select mf.path as from_path, '' as scope, tf.path as to_path, 'assoc' as kind
from app_associations a
join app_constants mf on mf.constant = a.class_name
join app_constants tf on tf.constant = a.target
where a.target is not null and tf.path <> mf.path;

create view v_code_edges as
select from_path, scope, to_path, kind from v_action_view_edges
union all select from_path, scope, to_path, kind from v_const_edges
union all select from_path, scope, to_path, kind from v_render_edges
union all select from_path, scope, to_path, kind from v_render_candidate_edges
union all select from_path, scope, to_path, kind from v_assoc_edges;
```

**Точки входа и достижимость.** Точка входа — это место, откуда код начинает
выполняться, И среда, в которой это происходит: роутованные контроллеры во всех
средах, фоновые работы в тех средах, где включены, службы каналов, задачи
сборщика через состав служб.

```sql
-- ГДЕ КОД ВЫПОЛНЯЕТСЯ, И ЧТО ДЕЛАТЬ, ЕСЛИ МЕСТ НЕТ. Достижимость считается по
-- местам, а места берутся из состава служб живых контейнеров — которого у
-- проекта без ssh попросту нет. Тогда каждое соединение ниже даёт НОЛЬ строк,
-- точки входа исчезают все, и отчёт говорит «достижимо от точки входа: 0» про
-- дерево, у которого с графом всё в порядке. Замерено в другом проекте: 19
-- файлов javascript, 11 связей по импортам, ноль достижимых. Одно
-- синтетическое место держит слой рабочим, а отчёт говорит, что мест не
-- описано, вместо того чтобы печатать нули.
create view v_places as
select distinct place from run_units
union
select 'local' where not exists (select 1 from run_units);

create view v_entry_points as
-- Роутованный контроллер — точка входа в КАЖДОЙ среде, где поднят веб.
select c.path, p.place, 'controller' as kind, c.class_name as entry
from app_controllers c
join app_routes r on r.controller_class = c.class_name
cross join v_places p
where c.path is not null
group by c.path, p.place, c.class_name
union all
-- Фоновая работа — только там, где она включена ('*' — везде).
select j.path, rp.place, 'job', j.class_name
from app_jobs j
cross join lateral unnest(j.places) as d(v)
join run_places rp on rp.env_id = d.v or d.v = '*'
where j.path is not null
union all
-- Тот же запасной путь для работ: если среды не описаны, работа по расписанию
-- всё равно точка входа — в том единственном месте, которое есть.
select j.path, p.place, 'job', j.class_name
from app_jobs j
cross join v_places p
where j.path is not null and not exists (select 1 from run_places)
union all
-- Служба каналов: поднята в каждой среде, а точкой входа не была — весь код,
-- доступный только из канала, лежал вне графа. Имя службы — НАСТРОЙКА
-- (`idioms.channel_service_units`): оно принадлежит одному приложению, и
-- приложению с другим именем пришлось бы править этот вид.
select c.path, u.place, 'channel', c.constant
from app_constants c
join run_units u on u.unit = any (array['channels-rpc']::text[])   -- из конфигурации
where c.path like 'app/channels/%'
union all
-- КОРНИ СБОРКИ JAVASCRIPT БЕРУТСЯ ИЗ ФАКТОВ. Корень сборки — точка входа, а не
-- мёртвый файл: его не импортирует никто по построению, сборщик начинает с
-- него. `js_entry` — это то, что называет сам конфиг сборщика, и разбор это уже
-- записал; образцы путей — запасной путь для дерева, чей конфиг прочесть не
-- удалось, и это НАСТРОЙКА (`idioms.js_entry_paths`). Вписанные как раскладка
-- одного сборщика, они оставили весь фронт проекта на другом сборщике вне
-- графа.
select f.path, p.place, 'pack', regexp_replace(f.path, '.*/', '')
from code_files f
cross join v_places p
where f.lang = 'js'
  and (exists (select 1 from code_refs e where e.kind = 'js_entry' and e.token = f.path)
       or f.path like any (array['app/javascript/packs/%']::text[]));   -- из конфигурации

-- Фоновые роботы: служба -> задача сборщика -> файл, где эта задача объявлена.
create view v_entry_rake as
select cr.path, u.place, u.task as scope, u.unit
from run_units u
join code_refs cr on cr.kind = 'task_entry' and cr.token = u.task
where u.task is not null;

create view v_reach as
with recursive seed as (
  select path, place from v_entry_points
  union select path, place from v_entry_rake
  union select e.to_path, s.place
         from v_entry_rake s
         join v_code_edges e on e.from_path = s.path and e.scope = s.scope
),
walk (path, place, depth) as (
  select path, place, 0 from seed
  union
  select e.to_path, w.place, w.depth + 1
  from walk w
  join v_code_edges e on e.from_path = w.path and e.scope = ''
  where w.depth < 9                  -- потолок: граф сходится на 5, запас на рост
)
select path, place, min(depth) as depth from walk group by path, place;
```

**Достижимость ошибается в обе стороны, и это надо записать в самом
представлении.** Вширь: ссылка на константу ещё не вызов, а условная ветка
неотличима от безусловной. Вглубь: вызов на объекте графу невидим, как и
динамический вызов по имени. Попадание сюда значит «похоже, достижимо»;
НЕ-попадание не значит ничего.

**Ради чего всё:**

```sql
create view v_break_here as
select r.token as table_name, rc.place, r.path, r.kind, rc.depth,
       array_to_string(r.lines, ',') as lines
from code_refs r
join v_table_presence tp on tp.name = r.token
join v_reach rc on rc.path = r.path
where r.kind in ('pg_table', 'pg_table_guess')
  and rc.place = any(tp.missing_in);
```

**Откуда в подстановку приходит текст.** Три дороги, и все три — кандидаты.
Главное здесь — **сила связи**: по одному совпавшему имени верить нельзя.

```sql
-- Разворот detail в колонки. `scopes` — все области, где встретилась эта же
-- подстановка: ряд один, а методы разные, и scope от первого про остальные врёт.
create view v_sql_holes as
select path, token as root, owner as context,
       detail->>'expr' as expr, detail->>'scope' as scope,
       array_to_string(array[detail->>'scope'] ||
                       coalesce(array(select jsonb_array_elements_text(detail->'scopes')), '{}'),
                       ', ') as scopes,
       coalesce((detail->>'blind')::boolean, false) as blind,
       coalesce((detail->>'fragment')::boolean, false) as fragment,
       detail->>'carrier' as carrier, detail->>'call' as call,
       detail->>'const' as const, detail->>'sql' as sql,
       count, lines
from code_refs where kind = 'sql_hole';

create view v_assigns as
select path, token as name, owner as scope, detail->>'value' as value,
       coalesce((detail->>'sql')::boolean, false) as is_sql,
       coalesce((detail->>'part')::boolean, false) as is_part,
       coalesce((detail->>'carrier')::boolean, false) as carrier,
       detail->>'op' as op, detail->>'from' as from_call, detail->>'const' as from_const,
       detail->'more' as more, count, lines
from code_refs where kind = 'assign';

-- Три РАЗНЫХ признака, и путать их нельзя:
--   has_sql      — в теле метода есть запрос (верно почти для всех моделей);
--   returns_sql  — метод ВОЗВРАЩАЕТ предложение целиком;
--   returns_part — возвращает обрывок. Для подстановки это то же самое.
create view v_defs as
select path, token as method, nullif(owner, '') as class_name,
       coalesce((detail->>'sql')::boolean, false) as has_sql,
       coalesce((detail->>'returns')::boolean, false) as returns_sql,
       coalesce((detail->>'returns_part')::boolean, false) as returns_part,
       coalesce((detail->>'singleton')::boolean, false) as singleton,
       coalesce(detail->>'visibility', 'public') as visibility,
       coalesce(array(select jsonb_array_elements_text(detail->'params')), '{}') as params,
       count, lines
from code_refs where kind = 'def';

create view v_sql_hole_source as
with h as (
  select *, nullif(regexp_replace(scope, '[#.][^#.]*$', ''), '') as class_name
  from v_sql_holes
),
d as (
  select *, (returns_sql or returns_part) as gives_sql from v_defs
)
-- тому же имени что-то присваивали
select h.path, h.root, h.context, h.expr, h.scope, h.lines as hole_lines,
       'assign' as source_kind, a.path as source_path, a.scope as source_scope,
       a.value as source_value, (a.is_sql or a.is_part) as source_is_sql,
       case when a.path = h.path then 'файл'
            when regexp_replace(a.scope, '[#.][^#.]*$', '') = h.class_name then 'класс'
            else 'имя' end as match
from h
join v_assigns a
  on a.name = h.root
 -- Локальная переменная ищется ТОЛЬКО в своём файле: локальные `sql` из разных
 -- файлов не связаны между собой никак. @/$/КОНСТАНТА — по всему дереву.
 and (a.path = h.path or h.root ~ '^[@$]' or h.root ~ '^[A-Z]')
union all
-- так называется метод; `h.call` — для `Repo.new.take_all`, где корень константа
select h.path, h.root, h.context, h.expr, h.scope, h.lines,
       'def', d.path, coalesce(d.class_name, ''), '', d.gives_sql,
       case when d.path = h.path then 'файл'
            when d.class_name = h.class_name then 'класс'
            when h.const is not null and d.path = c.path then 'класс'
            else 'имя' end
from h
left join app_constants c on c.constant = h.const
join d on d.method = coalesce(h.call, h.root)
union all
-- присвоили вызовом (`cond = build_cond`), и вот этот метод
select h.path, h.root, h.context, h.expr, h.scope, h.lines,
       'assign->def', d.path, coalesce(d.class_name, ''), a.value, d.gives_sql,
       case when d.path = h.path then 'файл'
            when d.class_name = h.class_name then 'класс'
            when a.from_const is not null and d.path = c.path then 'класс'
            else 'имя' end
from h
join v_assigns a on a.name = h.root and a.path = h.path and a.from_call is not null
left join app_constants c on c.constant = a.from_const
join d on d.method = a.from_call;
```

**Если источника нет, скажите почему.** Подстановка, чей корень — параметр
метода, в котором она стоит: текст приходит от вызывающего, и молчание тут
читается как «источника нет», хотя он есть и лежит на шаг выше.

```sql
create view v_sql_hole_from_param as
select h.path, h.root, h.context, h.expr, h.scope, h.lines, d.method, d.params
from v_sql_holes h
join v_defs d
  on d.path = h.path
 and h.scope = coalesce(d.class_name, '') || case when d.singleton then '.' else '#' end || d.method
 and h.root = any(d.params);
```

**Наблюдения — тремя представлениями: что трогали, чем именно и чего не знает
статика.** Разряд колонки («названа в выборке» против «по ней отбирают») тут так же
важен, как в статическом разборе.

```sql
-- `days` — в скольких сутках окна это видели. Без такого числа «в бою трогали» и
-- «в бою трогали один раз за сто суток» — одно утверждение, а это разные вещи.
create view v_runtime_table as
select t.name as table_name, r.place, sum(r.hits)::bigint as hits,
       count(distinct r.digest)::int as queries, max(r.day) as last_day,
       count(distinct r.day)::int as days
from sql_runtime r cross join lateral unnest(r.tables) as t(name)
group by 1, 2;

create view v_runtime_column as
select c.name as column_name, r.place, sum(r.hits)::bigint as hits,
       count(distinct r.digest)::int as queries, max(r.day) as last_day,
       count(distinct r.day)::int as days,
       bool_or(c.name = any(r.writes)) as written,
       bool_or(c.name = any(r.filters)) as filtered
from sql_runtime r
cross join lateral unnest(r.columns || r.filters || r.writes) as c(name)
group by 1, 2;

-- Окно наблюдения. Печатайте его рядом с КАЖДЫМ «в бою не трогали»: само по себе
-- это утверждение нечитаемо — за одни сутки не трогали и за сто суток не трогали
-- отличаются всем, а выглядят одинаково.
create view v_runtime_window as
select min(day) as first_day, max(day) as last_day,
       count(distinct day)::int as days, count(distinct place)::int as places,
       count(distinct host)::int as hosts, count(*)::int as skeletons,
       sum(hits)::bigint as hits,
       count(*) filter (where not parsed)::int as unparsed
from sql_runtime;

-- Таблица работала в бою, а в коде её не называет ни один разобранный запрос:
-- либо имя собирается интерполяцией (тогда это ответ на слепую зону), либо её
-- трогает не это приложение.
create view v_runtime_unknown_table as
select rt.table_name, rt.place, rt.hits, rt.queries, rt.last_day
from v_runtime_table rt
where not exists (select 1 from code_refs c
                  where c.kind in ('pg_table', 'pg_table_guess') and c.token = rt.table_name);
```

**Ключи окружения и тексты — тоже сверка двух списков.** Разряды в обоих случаях
решают больше, чем сам список: без них отчёт получается стеной.

```sql
create view v_env_usage as
select r.token as name, count(distinct r.path)::int as files,
       array_agg(distinct r.path order by r.path) as paths,
       count(distinct r.path) filter (
         where (r.path like 'app/%' or r.path like 'config/%'
                or (r.path like 'lib/%' and r.path not like 'lib/tasks/%'))
           and r.path not like 'spec/%')::int as app_files,
       count(distinct r.path) filter (
         where r.path like 'lib/tasks/%' or r.path like 'script/%')::int as task_files,
       array(select k.place from env_keys k where k.name = r.token order by k.place) as set_in,
       exists (select 1 from code_refs d where d.kind = 'env_default' and d.token = r.token) as has_default,
       exists (select 1 from code_refs f where f.kind = 'env_flag' and f.token = r.token) as is_flag
from code_refs r where r.kind = 'env_key' group by 1;

create view v_i18n_usage as
select r.token as key, count(distinct r.path)::int as files,
       array_agg(distinct r.path order by r.path) as paths,
       -- Ключ бывает и ПРОСТРАНСТВОМ: `t('about')` отдаёт хеш, и код обходит его
       -- как список. Без проверки на префикс такие ключи попадают в «перевода нет».
       (exists (select 1 from locale_keys k where k.key = r.token)
        or exists (select 1 from locale_keys k where k.key like r.token || '.%')) as in_store,
       (exists (select 1 from locale_keys k where k.key = r.token and k.lang = 'en')
        or exists (select 1 from locale_keys k where k.key like r.token || '.%' and k.lang = 'en')) as in_en,
       (select count(distinct k.lang) from locale_keys k where k.key = r.token)::int as langs
from code_refs r where r.kind = 'i18n_key' group by 1;

create view v_locale_orphan as
select k.key, count(distinct k.lang)::int as langs,
       array_agg(distinct k.file order by k.file) as files
from locale_keys k
where k.key <> ''
  and not exists (select 1 from code_refs r where r.kind = 'i18n_key' and r.token = k.key)
  and not exists (select 1 from code_refs r where r.kind = 'i18n_key' and k.key like r.token || '.%')
  -- Узор обязан быть ИЗБИРАТЕЛЬНЫМ: узор из одной подстановки совпадает с любым
  -- ключом и «объясняет» сразу всё, то есть ничего.
  and not exists (select 1 from code_refs d where d.kind = 'i18n_dynamic'
                  and length(replace(d.token, '$1', '')) >= 4
                  and k.key like replace(d.token, '$1', '%'))
group by 1;
```

**Сведите замер данных в слово.** Три числа рядом читают неверно; вердикт читают
правильно. Порог «умолчание почти у всех» нужен потому, что семнадцать строк из
трёх миллионов — это тоже «никто не трогал».

```sql
create view v_column_fill as
select source, table_name, column_name, rows_total, rows_recent, filled, off_default,
       filled_recent, recent_by, measured_at,
       case when filled = 0 then 'пусто'
            when off_default = 0 then 'всё по умолчанию'
            when off_default is not null and rows_total > 0
                 and off_default < rows_total / 1000 then 'умолчание почти у всех'
            when rows_recent > 0 and filled_recent = 0 then 'у новых не заполняется'
            -- Доля у свежей когорты в десять раз ниже общей — механика угасает, и
            -- по общему счёту этого не видно вовсе.
            when rows_recent > 0 and filled > 0
                 and filled_recent::numeric / rows_recent < (filled::numeric / rows_total) / 10
              then 'у новых почти не заполняется'
            else 'заполняется' end as verdict,
       case when rows_total > 0 then round(100.0 * filled / rows_total, 2) else 0 end as share
from column_fill;

-- Индекс, которого никто не читал. Первичные и уникальные не в счёт: они держат
-- ограничение, а не ускоряют выборку.
create view v_index_unused as
select source, table_name, index_name, size_bytes, since, measured_at,
       pg_size_pretty(size_bytes) as size
from index_usage
where scans = 0 and not is_primary and not is_unique;
```

**Слепые зоны — отдельным представлением, и ТОЛЬКО то, что осталось
неизвестным.** Если имя собрано из переменной, а переменная присвоена рядом, ответ
есть — держать это в счёте незнания значит врать про себя. И «кусок запроса» с
человеческим текстом — не слепая зона: там нечего не знать.

```sql
create view v_blind as
select path, kind, token, count, lines, detail
from code_refs
where kind in ('sql_blind', 'hb_dynamic', 'scan_error')
  and detail->>'resolved' is null;

-- Имя собрано на лету, но найдено по присваиванию в том же файле.
create view v_blind_resolved as
select path, token, detail->>'resolved' as table_name, lines, count
from code_refs where kind = 'sql_blind' and detail->>'resolved' is not null;

-- Кусок запроса или фраза, начавшаяся с ключевого слова. НЕ слепая зона.
create view v_sql_piece as
select path, token as text, detail->>'error' as error, lines, count
from code_refs where kind = 'sql_piece';
```

**Слой документации — два представления, где логика не очевидна.** Остальные
(ссылки, пути, разделы, имена) — простые проекции своих видов записей.

```sql
-- Разряд блока кода в документе. Это главное представление слоя: без разрядов
-- «не разобралось» было ложной тревогой на 137 блоков при четырнадцати
-- настоящих, а ложная тревога обесценивает все остальные ответы.
create view v_doc_code as
select path as doc,
       case kind
         when 'doc_code' then 'блок'
         when 'doc_code_sketch' then 'набросок'        -- …, <номер ДЦ>: человеческий пропуск
         when 'doc_code_excerpt' then 'отрывок'        -- обрыв посреди ветвления
         when 'doc_code_fragment' then 'кусок запроса' -- достроен приставкой
         when 'doc_code_patch' then 'заплатка'         -- diff, а не код
         when 'doc_code_dialect' then 'другой диалект' -- валидный SQL чужого движка
         when 'doc_code_broken' then 'НЕ РАЗОБРАЛСЯ'
       end as verdict,
       token as lang, owner as detail, lines,
       coalesce((detail->>'lines')::int, 0) as size
from code_refs
where kind in ('doc_code', 'doc_code_sketch', 'doc_code_excerpt', 'doc_code_fragment',
               'doc_code_patch', 'doc_code_dialect', 'doc_code_broken');

-- Документ называет таблицу, которой нет ни в одном снимке схемы. Это ВОПРОС, а
-- не приговор: так выглядит и снятая таблица, и ещё не созданная (планы полны
-- предлагаемых). Поэтому рядом — трогает ли её код: если нет, документ про
-- прошлое или про будущее, а не про сегодня.
create view v_doc_table_unknown as
select n.name as table_name, count(distinct n.doc)::int as docs,
       array_agg(distinct n.doc order by n.doc) as docs_list,
       exists (select 1 from code_refs r
               where r.kind in ('pg_table', 'pg_table_guess') and r.token = n.name) as in_code
from (select path as doc, token as name from code_refs where kind = 'doc_table') n
where not exists (select 1 from v_tables t where t.name = n.name)
  and not exists (select 1 from db_routines d join v_current c on c.snapshot_id = d.snapshot_id
                  where d.name = n.name)
group by 1;
```

**Виды обращения к колонке по имени — отдельными представлениями.** Они
понадобятся отчёту «какие поля не используются»: первые два считаются
использованием, третий — слепое место, которое печатается числом.

```sql
-- Берут значение по ключу-литералу. Таблица известна там, где видно, КАКИМ
-- запросом наполнена строка-ответ; где не видно — пусто, и сила связи остаётся
-- ИМЯ. Отчёт обязан говорить, какой из двух случаев перед ним.
create view v_column_value_read as
select token as column_name, nullif(owner, '') as table_name, path, lines, count
from code_refs where kind = 'key_read';

-- Имя, собранное интерполяцией: `g$1`, `language$1_2`. Колонку серии по слову не
-- найти — её имени в дереве нет вовсе.
create view v_name_pattern as
select token as pattern, path, detail->>'expr' as expr, detail->>'scope' as scope, lines
from code_refs where kind = 'name_pattern';

create view v_column_key_pattern as
select token as pattern, path, detail->>'expr' as expr, detail->>'scope' as scope, lines
from code_refs where kind = 'key_pattern';

-- Ключ-переменная: `row[field]` в цикле по списку полей. Какая это колонка —
-- неизвестно; молчать нельзя, иначе «значение не берут нигде» выдаётся за факт
-- там, где его просто не видно.
create view v_column_key_dynamic as
select path, nullif(owner, '') as table_name, detail->>'expr' as expr,
       detail->>'scope' as scope, lines, count
from code_refs where kind = 'key_dynamic';

-- `select *` и что из этой строки РЕАЛЬНО берут: превращает допущение в замер.
-- Прячет звезда ровно одно — обращение, где ключ переменная. Таких обращений два
-- разряда, и смешивать их нельзя: `keys_dynamic` точно на строке этой таблицы,
-- `keys_dynamic_file` — с неизвестной таблицей, но в тех же файлах, где её
-- выбирают звездой (в файле, который к таблице не ходит, обращение к её строке
-- невозможно). Оба нуля вместе и означают доказательство.
create view v_star_coverage as
with star as (select owner as table_name, count(distinct path)::int as files,
                     sum(count)::int as places
              from code_refs where kind = 'pg_select_star' and owner <> '' group by 1)
select s.table_name, s.files, s.places,
       (select count(distinct r.token)::int from code_refs r
        where r.kind = 'key_read' and r.owner = s.table_name) as keys_read,
       (select count(distinct r.token)::int from code_refs r
        where r.kind = 'key_pattern' and r.owner = s.table_name) as key_patterns,
       (select coalesce(sum(r.count), 0)::int from code_refs r
        where r.kind = 'key_dynamic' and r.owner = s.table_name) as keys_dynamic,
       (select coalesce(sum(r.count), 0)::int from code_refs r
        where r.kind = 'key_dynamic' and r.owner = ''
          and r.path in (select x.path from code_refs x
                         where x.kind = 'pg_select_star' and x.owner = s.table_name)
       ) as keys_dynamic_file,
       (select count(distinct c.column_name)::int from v_columns c
        where c.table_name = s.table_name) as columns
from star s;
```

**Колонка, которой в таблице нет ни в одной среде, — поломка, а не находка про
неиспользуемое.** Системные колонки отсевайте (`ctid`, `oid` в каталоге не
числятся, но есть у каждой таблицы), подстановку в имени — тоже. Подсказка
«похоже на» делает отчёт готовой правкой: три из пяти наших находок были промахом
на одно слово.

```sql
create view v_column_blind as
select r.owner as table_name, r.token as column_name,
       case r.kind when 'pg_column_write' then 'запись' else 'чтение' end as mode,
       (select string_agg(n.column_name, ', ' order by n.column_name)
        from (select distinct column_name from v_columns where table_name = r.owner) n
        where n.column_name like left(r.token, greatest(length(r.token) / 2, 4)) || '%'
           or r.token like left(n.column_name, greatest(length(n.column_name) / 2, 4)) || '%') as looks_like,
       r.path, r.lines, r.count
from code_refs r
join (select distinct table_name from v_columns) t on t.table_name = r.owner
left join (select distinct table_name, column_name from v_columns) c
  on c.table_name = r.owner and c.column_name = r.token
where r.kind in ('pg_column', 'pg_column_write')
  and r.owner <> '' and c.column_name is null
  and r.token <> all (array['ctid', 'oid', 'xmin', 'xmax', 'cmin', 'cmax', 'tableoid'])
  and position('$1' in r.token) = 0;
```

**Список полей привязывается к таблице по составу имён, и этим проверяется сам.**
Сам список — такая же запись индекса; повторы в составе склеены, но запомнены
отдельно, иначе проверить повтор механически нечем.

```sql
create view v_column_lists as
select path, token as name, owner as scope,
       coalesce(array(select jsonb_array_elements_text(detail->'columns')), '{}') as columns,
       coalesce((detail->>'size')::int, 0) as size,
       coalesce(detail->'dups', '{}'::jsonb) as dups, lines
from code_refs where kind = 'col_list';
```

Доля совпавших имён — мера уверенности; требуйте и доли, и минимального числа
совпадений, иначе в дефекты лезут наборы слов, случайно совпавшие с колонками.

```sql
create view v_list_table as
select distinct on (path, name) path, name, table_name, matched, size,
       (100 * matched / greatest(size, 1))::int as share
from (select l.path, l.name, c.table_name, l.size, count(distinct u.col)::int as matched
      from v_column_lists l
      cross join lateral unnest(l.columns) as u(col)
      join (select distinct table_name, column_name from v_columns) c on c.column_name = u.col
      group by 1, 2, 3, 4) q
order by path, name, matched desc, table_name;

create view v_column_list_defect as
select 'повтор в списке' as kind, l.path, l.name as list_name,
       t.table_name, d.key as column_name, (d.value #>> '{}')::int as times
from v_column_lists l
join v_list_table t on t.path = l.path and t.name = l.name
                   and t.share >= 60 and t.matched >= 5
cross join lateral jsonb_each(l.dups) as d(key, value)
-- Числовые и односимвольные «имена» — не колонки: в дереве есть таблица с
-- колонками `1`…`33` и другая с `a`…`t`, и без отсева они дают сотню ложных строк.
where d.key !~ '^[0-9]+$' and length(d.key) >= 3
union all
select 'пропуск в серии', t.path, t.name, t.table_name, c.column_name,
       (select count(*)::int from unnest(l.columns) as s(col)
        where regexp_replace(s.col, '[0-9]+$', '') = regexp_replace(c.column_name, '[0-9]+$', ''))
from v_list_table t
join v_column_lists l on l.path = t.path and l.name = t.name
join (select distinct table_name, column_name from v_columns) c on c.table_name = t.table_name
where t.share >= 60 and t.matched >= 5
  and c.column_name <> all (l.columns)
  and c.column_name ~ '[0-9]$'
  and regexp_replace(c.column_name, '[0-9]+$', '') <> ''
  and (select count(*) from unnest(l.columns) as s(col)
       where regexp_replace(s.col, '[0-9]+$', '') = regexp_replace(c.column_name, '[0-9]+$', '')) >= 2;

-- Журнал проверок находок (VI.3): вердикт вместе с его СВЕЖЕСТЬЮ. Состояние
-- считается здесь и только здесь — повторить это правило во втором месте значит
-- дать им разойтись.
create view v_finding_verdict as
select v.kind, v.subject, v.verdict, v.checked, v.reason, v.path, v.checked_at, v.git_sha,
       case
         when v.path is null then 'без файла'   -- не стареет никогда, и это надо говорить вслух
         when f.path is null then 'файла нет'
         when f.sha = v.file_sha then 'свежий'
         else 'устарел'                         -- файл правили: находка возвращается в отчёт
       end as state
from finding_verdicts v
left join code_files f on f.path = v.path;

-- Что отсеивается из отчётов. Только «ложная» и только пока вердикт свеж.
create view v_finding_hidden as
select kind, subject, reason, checked, checked_at
from v_finding_verdict
where verdict = 'ложная' and state <> 'устарел';

-- Надёжность разряда: насколько верить НОВОЙ находке этого вида. (продолжение
-- Части V — виды слоёв стилей и javascript идут после этого блока.)
create view v_finding_reliability as
select kind,
       count(*)::int as checked,
       count(*) filter (where verdict = 'ложная')::int as wrong,
       count(*) filter (where verdict = 'настоящая')::int as genuine,
       (100 * count(*) filter (where verdict = 'ложная') / greatest(count(*), 1))::int as wrong_share,
       count(*) filter (where state = 'устарел')::int as stale,
       count(*) filter (where state = 'без файла')::int as timeless,
       max(checked_at) as last_checked
from v_finding_verdict group by kind;
```

**Стили: «чем файл жив» — это CASE, и каждая его ветка однажды спасла живой
файл от списка на снятие** (IV.18). Порядок ветвей значим: разряд назначается
первым совпадением, поэтому поставляемое и отдаваемое как файл стоят раньше
способов подключения.

```sql
create view v_css_file as
select f.path, f.bytes,
       (select count(*) from code_refs c where c.kind = 'css_class' and c.path = f.path)::int as classes,
       (select count(*) from code_refs i where i.kind = 'css_import' and i.path = f.path)::int as imports
from code_files f where f.lang = 'css';

create view v_css_edges as
select path as from_path, '' as scope, token as to_path, 'css_import' as kind
from code_refs where kind = 'css_import';

create view v_css_unreachable as
select f.path, f.bytes, f.classes,
       case
         when f.path like '%/vendor/%' or f.path like 'vendor/%'
           or f.path like 'node_modules/%' then 'поставляемое'
         when f.path like 'public/%' then 'отдаётся как файл'
         when exists (select 1 from code_refs e where e.kind = 'js_entry' and e.token = f.path)
           then 'вход сборки'
         when exists (select 1 from v_css_edges e where e.to_path = f.path) then 'подключён @import'
         -- Стиль тянет и JAVASCRIPT: `import '../css/uppy_upload.css'` в корне
         -- пака, и сборщик отдаёт css побочным выходом. Без этой ветки живой
         -- файл попадает в кандидаты на снятие.
         when exists (select 1 from code_refs j
                      where j.kind = 'js_import' and j.token = f.path) then 'подключён из javascript'
         when exists (select 1 from code_refs r where r.kind = 'asset_ref' and r.token = f.path)
           then 'упомянут в шаблоне'
         else 'КАНДИДАТ НА СНЯТИЕ'
       end as kind
from v_css_file f;
```

**Цепочка «контур → пак → вход сборки → `@import` → файл» — рекурсивный вид
плюс одно соглашение имён, названное вслух.**

```sql
create view v_pack_entry as
select detail->>'pack' as pack, token as entry, path as config, 'ключ конфига' as how
from code_refs where kind = 'js_entry' and detail->>'pack' is not null
union
-- ПО СОГЛАШЕНИЮ ИМЁН: у входа, собранного в конфиге из частей
-- (`path.join(root,'app','javascript','x','x.css')`), ключа нет вовсе, а шаблон
-- просит пак по имени `x`. Имя пака совпадает с именем файла входа без
-- расширения — связываем по нему. Без этого у контура не оказывается НИ ОДНОГО
-- своего стиля, и вид честно, но бесполезно отвечает «правила в контуре нет».
select r.token as pack, e.token as entry, e.path as config, 'по имени файла' as how
from code_refs e
join code_refs r on r.kind = 'pack_ref'
               and r.token = regexp_replace(regexp_replace(e.token, '.*/', ''), '\.[a-z]+$', '')
where e.kind = 'js_entry' and e.detail->>'pack' is null;

create view v_pack_css as
with recursive reach as (
  select e.pack, e.entry as path from v_pack_entry e
  union
  select r.pack, d.to_path from reach r join v_css_edges d on d.from_path = r.path
)
select pack, path from reach
where exists (select 1 from code_files f where f.path = reach.path and f.lang = 'css');

create view v_pack_ref as
select r.path, r.token as pack,
       case
         when r.path like 'app/views/layouts/%'
           -- `split_part` вместо регулярки нарочно: обратный слэш в образце не
           -- доживал до SQL через два слоя кавычек, и имя контура выходило
           -- ПУСТЫМ — вид молча отдавал ноль строк.
           then split_part(regexp_replace(r.path, '.*/', ''), '.', 1)
         when r.path like 'app/views/%'
           then split_part(regexp_replace(r.path, '^app/views/', ''), '/', 1)
         else 'вне шаблонов'
       end as contour
from code_refs r where r.kind = 'pack_ref';
```

**Класс: объявление, потребители, узор и вердикт.** Вердикт один на имя, и
«подходит под узор» — отдельный разряд, а не «поминают»: это не доказательство
использования, но и не повод снимать.

```sql
create view v_css_class as
select c.path, c.token as name, c.lines,
       (select kind from v_css_unreachable u where u.path = c.path) as file_kind
from code_refs c where c.kind = 'css_class';

create view v_css_class_use as
select token as name, 'разметка' as how, path, lines from code_refs where kind = 'html_class'
union all
select token as name, '@apply' as how, path, lines from code_refs where kind = 'css_apply';

create view v_css_class_pattern as
select token as pattern, detail->>'glob' as glob, path, lines
from code_refs where kind = 'html_class_pattern' and detail->>'glob' is not null;

create view v_css_class_usage as
select c.name, min(c.path) as declared_in, count(distinct c.path)::int as files,
       case
         when exists (select 1 from v_css_class_use u where u.name = c.name) then 'поминают'
         when exists (select 1 from v_css_class_pattern p
                      where c.name like p.glob escape '~') then 'подходит под узор'
         when min(c.file_kind) = 'КАНДИДАТ НА СНЯТИЕ' then 'файл никто не подключает'
         when min(c.file_kind) = 'поставляемое' then 'поставляемый стиль'
         else 'НЕ ПОМИНАЕТ НИКТО'
       end as verdict
from v_css_class c group by c.name;

create view v_css_class_contour as
with contour_pack as (
  -- КОНТУР — только тот, у которого цепочка доказуема: макет своего имени
  -- называет пак. Каталог шаблонов контуром не является (он рисуется под
  -- макетом, который выбирается на ходу), и приписывать ему стили значит
  -- отвечать неправдой. Таких «контуров» первый вариант выдумал пять.
  select contour, pack from v_pack_ref where path like 'app/views/layouts/%'
),
contour_css as (
  select distinct cp.contour, c.path
  from contour_pack cp join v_pack_css c on c.pack = cp.pack
),
used as (
  select split_part(regexp_replace(r.path, '^app/views/', ''), '/', 1) as contour,
         r.token as name, r.path
  from code_refs r
  where r.kind = 'html_class' and r.path like 'app/views/%'
)
select u.contour, u.name, count(distinct u.path)::int as templates,
       case
         when exists (select 1 from contour_css cc join v_css_class d on d.path = cc.path
                      where cc.contour = u.contour and d.name = u.name) then 'правило в контуре есть'
         when not exists (select 1 from contour_css cc where cc.contour = u.contour)
           then 'паки контура не сопоставлены входам'
         when exists (select 1 from v_css_class d where d.name = u.name)
           then 'правило есть, но в другом контуре'
         else 'правила нет ни в одном НАШЕМ стиле'
       end as verdict
from used u
where u.contour in (select contour from contour_pack)
group by u.contour, u.name;
```

**Javascript: разряд файла вместо одного слова «недостижим», и вызов как
зацепка** (IV.19). В самом инструменте у `v_js_unreachable` стоит ещё колонка
«упомянут в документе» — она тянет слой документов и здесь опущена, чтобы блок
оставался самодостаточным.

```sql
create view v_js_edges as
select path as from_path, '' as scope, token as to_path, 'import' as kind
from code_refs where kind = 'js_import';

create view v_js_unreachable as
select f.path, f.bytes,
       case
         when f.path like 'app/javascript/packs/%' then 'корень сборки'
         when f.path like 'script/%' then 'самостоятельный скрипт'
         when f.path like 'public/%' then 'отдаётся как файл'
         when f.path like 'vendor/%' then 'поставляемая зависимость'
         when exists (select 1 from code_refs e
                      where e.kind = 'js_entry' and e.token = f.path) then 'корень из конфига сборки'
         -- Три разряда файлов, которых не импортирует НИКТО и которые при этом
         -- живы: их читает не код, а инструмент. Без них восемь таких файлов
         -- стояли кандидатами на снятие и прятали бы настоящий мёртвый файл.
         when f.path like '%.d.ts' then 'объявление типов (читает tsc)'
         when f.path like '%.test.ts' or f.path like '%.spec.ts'
           or f.path like '%.test.js' or f.path like '%.spec.js' then 'прогон тестов'
         when f.path like '%.config.ts' or f.path like '%.config.js'
           or f.path like '%.config.mjs' then 'настройка сборки'
         else 'КАНДИДАТ НА СНЯТИЕ'
       end as kind
from code_files f
where f.lang = 'js'
  and not exists (select 1 from v_js_edges e where e.to_path = f.path);

create view v_js_func as
select path, token as name, nullif(owner, '') as scope, lines
from code_refs where kind = 'js_func';

create view v_js_call as
select path, token as name, lines from code_refs where kind = 'js_call';

-- «Не зовёт никто» тут — НАЧАЛО проверки, а не вывод: рядом едут экспорт и
-- разряд файла, потому что функцию ещё передают значением и зовут из скрипта.
create view v_js_func_unused as
select f.path, f.name, f.scope,
       exists (select 1 from code_refs e
               where e.kind = 'js_export' and e.path = f.path and e.token = f.name) as exported,
       (select u.kind from v_js_unreachable u where u.path = f.path) as file_kind
from v_js_func f
where not exists (select 1 from v_js_call c where c.name = f.name);

-- Библиотека: внутрь не лезем, считаем упоминания ПРИВЯЗКИ импорта.
create view v_js_package_use as
select b.owner as package,
       count(distinct b.path)::int as files,
       array_agg(distinct b.token order by b.token) as bindings,
       sum((b.detail->>'mentions')::int)::int as mentions
from code_refs b where b.kind = 'js_binding' and b.owner <> ''
group by 1;
```

---

# Часть VI. Отчёты

Правила, общие для всех отчётов. Нарушение любого убивает доверие к инструменту
быстрее, чем любая ошибка в разборе.

**Факт, кандидат и догадка — в разных разделах.** Не в одном списке с пометкой, а
именно в разных разделах с разными заголовками.

**Называйте силу связи у каждой строки.** `файл` / `класс` / `имя`. Последнее —
шум; его либо не печатать, либо отдельной строкой «ещё N связей найдено только по
совпадению имени — это не находки».

**Частое имя не раскрывайте.** Если имя объявлено в дереве девять раз и «вызовов»
у него тысяча шестьсот — это чужие вызовы. Печатайте «имя частое (N объявлений),
сводка не значит ничего», а не числа.

**Пустой список — это ответ, и он печатается словами.** «По имени не зовут нигде
— ни из кода, ни из шаблонов, ни через динамический вызов с именем-литералом;
остаётся перехват обращений и имя, собранное на лету». Молчание не ответ.

**«Мёртв» всегда вместе с «что его держит».** Рядом с «вызовов нет» печатайте
упоминания вне вызовов: тесты, описи, документы, конфигурации, комментарии. У нас
первая же находка была такой: метод не зовут нигде, но на его строку заведено
исключение в тесте-стороже. Удалять надо парой.

**Делите результат по силе вывода.** «Ничем не помянуто — снимается в одиночку»
и «держат упоминания — снимать парой». Первое — безопасный список, второе — на
разбор.

**Меряйте не только в штуках.** «Двести мёртвых методов» — число без масштаба.
Двести однострочных обёрток и двести стострочных разборов — разный разговор.
Границы метода берите у парсера, а не счётом до следующего объявления: между
методами лежат комментарии, и принадлежат они тому, что ниже.

**Защёлка вместо нуля.** Для архитектурных правил: столько нарушений терпим
сегодня, отчёт молчит, пока число не выросло. Этим же приёмом оформляется
счётчик незаконченного переноса — число должно только падать.

**Числа старятся.** Печатайте рядом команду, которая пересчитывает, и ставьте
оговорку «числа — на день правки».

---

## VI.0. Задержка — это свойство инструмента, а не его обвязки

Эту главу стоило бы поставить первой, потому что всё остальное от неё зависит.
Инструмент, который отвечает за шесть секунд, спрашивают только тогда, когда
вопрос заведомо структурный; в остальных случаях человек (и агент) тянется к
грепу — и пользуется не инструментом, а привычкой. Мы это обнаружили поздно и
измерили: `where` по таблице отвечал **6,5 с**, а `git grep` по тому же дереву —
**0,24 с**. При этом сам запрос к базе индекса занимал **0,04 с**. То есть
индекс был в двести раз быстрее `grep`, а обвязка вокруг него — в семьсот раз
медленнее.

Разбор по слагаемым оказался поучительнее самих чисел — ни одно из них не было
«ценой индекса»:

| куда ушло | сколько | что это было |
| --- | --- | --- |
| загрузка приложения | 3,1 с | отчётам не нужна: это SQL к локальной базе |
| хеширование всех файлов | 1,5 с | платилось на каждой команде при нулевых правках |
| соединение по именам видов | 2,3 с | условие не хешировалось, шёл вложенный цикл |
| сам запрос | 0,04 с | |

**Загрузка каркаса.** Отчёт — это SQL к своей базе; фреймворк там не нужен ни
для чего. Отдельная точка входа, которая грузит только слой базы данных и
драйвер, обходится в 0,4 с вместо 3,1. На приложении остаются ровно те задачи,
которым без него нельзя: те, что спрашивают факты у самого фреймворка (роуты,
модели, автозагрузка), и те, что ходят в базу приложения его подключением.
Условие для этого: внутри задач не должно быть обращений к фреймворку — у нас
`Rails.root` в семнадцати местах заменился своим `Xref.root`, который без
фреймворка падает на рабочий каталог.

**Догон индекса.** Считать контрольную сумму всех файлов на каждой команде —
1,5 с, которые почти всегда тратятся зря. Поставьте перед хешированием ворота по
времени правки: обойти те же файлы `stat` стоит 0,018 с, в восемьдесят раз
дешевле. **Время правки доказательством не считается ни в одну сторону:**
совпало — верим прежней сумме, разошлось — считаем сумму и сравниваем её.
Файл, перезаписанный тем же содержимым, разбор не повторяет.

Эти ворота ломаются В ОПАСНУЮ СТОРОНУ: пропустить изменившийся файл значит
отвечать по старому содержимому и при этом выглядеть свежим. Поэтому решение
выносится в отдельный чистый разбор (без файловой системы) и закрывается
спекой, в которой проверяется и экономия, и её безопасность — что лишнего не
хешируем И что изменившееся не пропускаем.

**Запросы.** Два места, где отчёт был медленным не из-за объёма, а из-за формы
условия, и оба лечатся одинаково:

* `v.token = r.token or right(v.token, length(r.token)+1) = '/' || r.token`
  индексом не берётся вовсе — планировщик идёт вложенным циклом и отбрасывает
  4,8 млн пар. Добавьте **первый ярус по последнему сегменту имени**: если
  полное имя оканчивается на `/` плюс искомое, последние сегменты равны
  непременно. Этот ярус хешируется, исходное условие остаётся фильтром. Ответ
  тот же, цена в тридцать пять раз меньше;
* три правила про ключи переводов, записанные через `LIKE` по всем 102 648
  ключам хранилища, стоили 94 с. Те же правила через **раскладку ключа на
  точечные приставки** (соединение равенством) — 0,6 с. Плюс два приёма:
  считать ярусы ПО ПОРЯДКУ (дорогой ярус — только для того, что не покрыли
  дешёвые) и сводить обе стороны к различным значениям ДО соединения (у нас
  102 648 строк на 8 959 ключей и 11 087 записей на 2 699 имён — соединение
  «как лежит» давало 179 139 пар вместо 2 699).

**После любой такой правки сверяйте ответ со старым определением выборкой в обе
стороны.** Не «похоже» и не «столько же строк», а `except` в обе стороны: у нас
обе переписки дали ноль расхождений, и только это позволяет их выпустить.

**Тяжёлое представление считайте один раз за команду.** Отчёты задают по
нескольку вопросов одному представлению; временная таблица живёт до конца
подключения, то есть ровно одну команду. И **то, что можно посчитать при
разборе, не считайте в отчёте**: длина метода была известна разборщику, а отчёт
про мёртвые методы трижды перечитывал и разбирал каждый файл с находкой.

Итог: 6,5 с → 1,3 с на запрос, 26 с → 2,5 с на обход графа, 318 с → 7,7 с на
отчёт о текстах. Это не косметика — это разница между «инструментом
пользуются» и «инструмент есть».

---

## VI.0.1. Поиск по тексту: обёрткой, а не своим индексом

Рано или поздно встаёт вопрос: инструмент отвечает на структурные вопросы, а на
«где встречается эта строка» не отвечает вовсе — и из-за этого остаётся вторым
инструментом рядом с `grep`. У нас слой кандидатов по словам знал 2 305 имён
(только имена из базы), поэтому любой вопрос про комментарий, адрес, текст
ошибки или ключ настройки уходил к текстовому поиску.

Соблазн — завести таблицу строк и поиск по триграммам. **Так делать не надо.**
Второй индекс старел бы отдельно от первого, требовал бы своего догона и своей
проверки на свежесть — то есть ровно той болезни, от которой инструмент лечат.

Правильный ход — **обёртка над готовым поиском**: она свежа по построению,
обслуживания не требует, а инструмент добавляет к находкам то, чего поиск не
знает: достижим ли файл из боя и с какой глубины, кто его зовёт, какие таблицы
трогает, сколько в нём слепых мест, рисуется ли он в живых логах. «Вместо грепа»
— это не «быстрее `grep`», это **«греп плюс смысл»**.

Три вещи, которые стоит знать заранее:

* **быстрый поиск может быть недоступен**, и тогда отвечать всё равно надо.
  Запасной путь — не ошибка; но отчёт обязан говорить, которым он шёл: у
  запасного другая цена (у нас 271 образец по 196 МБ — 0,9 с против 36 с);
* **сверьте два движка на одном вопросе.** У нас они расходились на пять находок
  из 67, и расходились молча: один по умолчанию не заходит в каталоги с точкой,
  а там лежат отслеживаемые файлы;
* **самая дорогая ловушка**: без явного пути `rg` при стандартном вводе не от
  терминала читает СТАНДАРТНЫЙ ВВОД, находит ноль и выходит с кодом «нет
  совпадений». Из руки та же команда отвечала 1 282 строками. Пустой ответ
  прочитали бы как «в дереве этого нет».

И мелочь, которая меняет пользу ответа больше, чем кажется: **печатайте текст
найденной строки**. Номер строки говорит ГДЕ, а решение принимается по тому, ЧТО
там, — иначе ответ отправляет открывать файл. У строки, открывающей heredoc,
своего содержания нет: берите две следующие, иначе половина ответов про запросы
останется бессодержательной.

**Тем же поиском лечатся и собственные проходы по дереву.** Отчёты задают три
вопроса, на которые раньше отвечал проход по 196 МБ в руби: «кто вообще поминает
эти имена» (33 с), «какие помощники роутов есть в дереве» (11 с) и «какие адреса
написаны строкой» (6 с). Все три — поиском: 1,3 с, 0,9 с и 0,4 с. Отчёт
«неиспользуемое» целиком ускорился со 80–140 с до 15 с, и это та разница, после
которой им начинают пользоваться.

Приём, без которого замена врёт: **поиск — ПРЕДФИЛЬТР, а решает выражение.**
Поиск ищет по основе имени (`часть_есть?` → `часть_есть`) и целым словом, то
есть находит заведомо больше нужного, а точное правило применяется к найденным
строкам уже своим разбором. Иначе приходится повторять правило на чужом
диалекте регулярных выражений — и оно разойдётся.

Четыре расхождения между поиском и полным проходом, каждое найдено сверкой
множеств, а не рассуждением, — и каждое стоило бы доверия к отчёту:

- **флаг нечувствительности не живёт в тексте выражения.** `source` его не
  несёт, и поиск нашёл 6 064 адреса вместо десяти тысяч — молча;
- **поиск смотрит строку за строкой**, поэтому у совпадения в НАЧАЛЕ строки нет
  предшествующего знака: без `^` в образце терялось 902 адреса;
- **поиск заходит туда, куда не ходил проход** (поставляемые зависимости,
  документация гемов) — нужны те же исключения, иначе в ответ лезет чужое;
- **проход не читает файлы крупнее порога, а поиск не читает двоичные.** У нас
  это 412 найденных дополнительно (машинные описи крупнее 4 МБ — та сторона, где
  ошибка опасна: «никто не поминает» читается как «можно снимать») против 863
  потерянных, и все 863 оказались мусором из png: с роутами приложения не
  совпал НИ ОДИН. Проверять надо именно так — не «сколько разошлось», а
  «меняет ли расхождение ответ».

---

## VI.1. Как проверять, что инструмент не врёт

Отчёт, который выглядит правильно, ничего не доказывает. На каждую способность
полезно иметь **контрольный опыт** — такой, после которого инструмент обязан
сказать вслух, что он чего-то не знает. Три опыта, которые стоит прогнать первыми;
каждый из них у нас однажды провалился.

**Смена схемы при прежнем исходном файле.** Добавьте колонку в базу, снимите
схему и НЕ трогайте ни один файл кода. Инструмент обязан заметить и перебрать
дерево заново. Если инкрементальность опирается только на контрольную сумму
файла — не заметит: сумма та же, а слой кандидатов и привязка колонок к моделям
уже другие. Проверять надо не факт переразбора, а его эффект: имя новой колонки
должно появиться в индексе. У нас — появилось четырьмя записями, которых до
правки не было бы никогда.

**Отключённый парсер.** Спрячьте парсер SQL и задайте тот же вопрос. Ответ обязан
отличаться от ответа при полном разборе. Если он совпадает — ноль находок у вас
неотличим от «не смотрели», и это худший вид лжи: его не видно.

**Новое запрещённое обращение.** Опустите защёлку архитектурного правила на
единицу и прогоните проверку: она обязана закричать. Опыт удобно делать правкой
конфигурации в памяти, не трогая файл.

Два следствия для отчётов:

- **состояние индекса — часть любого ответа.** Одна строка в шапке: сколько
  файлов, какой возраст снимков схем, сколько слепых мест. Отдельной громкой
  строкой — если снимки старше суток, если снятие у источника провалилось, если
  дерево разобрано при разных поколениях схемы, если парсера не было;
- **пустой ответ объясняет себя.** «Ноль при полном разборе — это отсутствие» и
  «ноль при неполном разборе — это может быть незнание» — разные утверждения, и
  печатать их надо разными словами.

## VI.2. От задачи к файлам, а не от файла

Отчёт «что прочитать перед правкой этого файла» начинает с середины: чтобы
спросить, надо уже знать, куда смотреть. Первым должен быть другой вопрос — **от
задачи**: принять роут, действие, таблицу, файл или просто слово и выдать порядок
**точки входа → карта → исходники**, а не список файлов вперемешку.

Четыре блока, в этом порядке:

1. **точки входа** — роуты с числом запросов из наблюдения (а не все подходящие
   по имени), таблицы с указанием сред, где их нет, файлы, совпавшие именем;
2. **читать первым** (шаг 1 по графу ссылок) и **дальше** (шаг 2);
3. **таблицы области, которых где-то нет** — чтобы читать исходники, уже зная,
   где это упадёт;
4. **сколько в области слепых мест и дыр в запросах** — честная мера того, какую
   часть области инструмент сам не понял.

Две вещи делают такой отчёт полезным, а не просто длинным.

**Раскладка шага по компонентам, код прежде шаблонов.** Без неё шаг 1 даёт девять
десятков файлов и не сокращает ничего. С ней видно: читать надо один контроллер,
девятнадцать файлов служебного слоя и восемь моделей, а шесть десятков шаблонов
сворачиваются в четыре строки с остатком «и ещё N». Порядок компонентов — тот же
ранг слоёв, что у архитектурных правил.

**Задача про колонку — не задача про таблицу.** Если на входе `таблица.колонка`,
начальными файлами берите те, где в запросе есть именно эта колонка, и к таблице
спускайтесь только когда по колонке не нашлось ничего. Иначе сорок файлов,
трогающих широкую таблицу, раздувают область в десять раз — и отчёт, который
обязан её сокращать, делает обратное. Колонка при этом в индексе лежит токеном при
владельце-таблице, а не строкой `таблица.колонка`: искать надо парой.

**Счёт далёких зависимостей.** Печатайте, сколько файлов пришло ТОЛЬКО по графу
ссылок и при этом не содержит ни одного слова задачи в пути: по имени файла их не
найти. Начальные файлы из счёта исключите — их находят и поиском, иначе число
хвалит инструмент за чужую работу. Слова задачи берите врозь: `users.email` — это
два слова, а целиком с точкой такого пути нет ни одного, и счёт вышел бы «про
всё». Это измеримая форма вопроса «находит ли карта заранее известную далёкую
зависимость»,
и ответ на ней не риторический: у нас по одной задаче таких файлов 156 из 243, и
среди них те, чьи имена с задачей не пересекаются ни одной буквой, — потому что
данные лежат в другом хранилище, и по имени задачи этого не видно никак.

## VI.3. Журнал проверок находок

Самый дорогой замер за всё время работы над этим инструментом, и он не про код.
Семь разрядов находок, проверенных у первоисточника подряд, за двое суток:

| разряд | отчёт сказал | настоящих | ложных |
| --- | ---: | ---: | ---: |
| сломанные примеры в документах | 137 | 7 | **95 %** |
| битые ссылки | 632 | 15 | **98 %** |
| `rewrite … last` | 25 | 2 | **92 %** |
| пропуски перевода | 22 | 6 | 73 % |
| обращения к несуществующей колонке | 13 | 4 | 69 % |
| мёртвые контроллеры Stimulus | 3 | 1 | 67 % |
| «не используется никем» (быстрая регулярка) | «больше десятка» | 1 | — |

Это не неряшливость разборщика — это **свойство нового слоя**. В слое, который
только что появился, ложных находок в два-три раза больше настоящих, и
становится их меньше ровно по мере того, как каждую проверяют у источника и
правило отсева переписывают. Сто тридцать семь сломанных примеров стали семью
после шести разрядов отсева (набросок, отрывок, заплатка, кусок запроса, чужой
диалект, врущая подпись языка) — и ни один из этих разрядов нельзя было
придумать заранее, их видно только на находках.

Отсюда три вывода, и все три — про устройство инструмента, а не про усердие.

**Проверку надо хранить рядом с находкой.** Каждая из тех семи проверок стоила
получаса чтения первоисточника, и всё знание оставалось в сообщении коммита.
Поэтому в индексе лежит таблица вердиктов: разряд, предмет, вердикт
(`настоящая`/`ложная`), чем проверено, почему, и SHA файла на момент проверки.

**Проверенное ложным в отчёт больше не попадает.** Иначе его проверяют заново
каждый раз, а отчёт учатся пролистывать — и тогда настоящая находка тонет не в
шуме инструмента, а в привычке читателя. Отсев идёт по ОДНОМУ выражению
предмета, написанному в одном месте (`Xref::Verdicts::KINDS`): разойдись два
написания — и вердикт молча перестанет узнавать свою находку.

**Рядом с разрядом печатается его надёжность.** «Проверено 13, ложных 9 (69 %)»
— это ответ на вопрос, которого инструмент не умел задавать: насколько верить
НОВОЙ находке этого вида. Без этого числа все находки читаются одинаково
весомо, а они не равны: в одном разряде ошибается каждая третья, в другом —
девятнадцать из двадцати.

Опасность у журнала ровно одна, и она того же рода, что у ворот перед
хешированием: **вердикт «ложная» прячет находку, то есть может скрыть настоящую
беду, появившуюся позже в том же месте.** Поэтому вердикт привязан к SHA файла:
файл изменился — вердикт **устарел**, находка вернулась в отчёт с пометкой.
Разряды, у которых файла нет вовсе (ключ перевода, индекс в базе, имя таблицы
из документа), не стареют никогда, и отчёт обязан сказать это вслух — у нас
такой вердикт печатается словами «из отчётов убрана НАВСЕГДА».

И последнее, без чего журнал превращается в способ прятать неудобное: **отчёт
обязан показывать, что он скрыл.** `bin/xref findings <разряд>` печатает три
списка — открытые находки, проверенные и признанные ложными (с причиной и
датой) и проверенные и подтверждённые. Отчёт, который молча убирает находки,
опаснее отчёта с шумом: про шум читатель знает, а про молчание — нет.

```sh
bin/xref findings                     # разряды: открыто / проверено / доля ложных
bin/xref findings column              # список предметов разряда
bin/xref verdict column "app/models/order.rb:rewards.points" \
         ложная "метод снят в 2024, звать его некому" схемой
```

**Реестр разрядов растёт вместе со слоями, и это главная причина держать его
одним списком.** У нас 17 разрядов (от «код ходит в колонку, которой нет» до
«класс объявлен, а не поминает никто»), 37 проверок в восьми из них, 22 находки
скрыты как ложные. Новый слой добавляет разряд, а не свою механику отсева:
добавил строку в реестр — и у разряда сразу есть и журнал, и доля ложных, и
«отчёт показывает, что скрыл».

И три вещи, которые на самом журнале выучились:

- **якорь бывает неполным, и это надо печатать.** У ключа перевода файла нет;
  якорем взят первый зовущий файл, но ключ зовут из нескольких мест, и правка
  второго вердикт не отменит. Неполный якорь лучше отсутствующего — но только
  если про его неполноту сказано;
- **правка правила отсева сильнее вердикта**, когда причина у находок общая:
  три из семи неразобранных примеров в документах оказались человеческими
  записями — это три новых разряда отсева и три примера в спеках, а не три
  вердикта. Вердикт — для одиночного случая;
- **молчаливый no-op у самой записи вердикта.** В чужой копии инструмента
  команда записи печатала «запомнено», а в базу не писала ничего (разошлись
  имена разрядов). Поэтому запись вердикта обязана проверять СВОЙ ЭФФЕКТ:
  посчитать находки до и после и сказать, изменилось ли число.

# Часть VII. Правила, которые дороже кода

Если из спецификации останется один раздел, пусть будет этот. Каждый пункт
однажды стоил инцидента, потерянных данных или ложного отчёта.

1. **Инструмент, который не называет своих слепых мест, врёт молча.** Отсутствие
   записи читается как «связей нет». Молчание — не ответ; «не знаю» — ответ.
2. **Отсутствие доказательства не есть доказательство отсутствия.** Логи за сутки
   доказывают, что экран используется, и ничего не говорят о том, что он мёртв.
   Пишите это прямо в отчёте, рядом с числами.
3. **Проверяйте, что правка подействовала.** Если после ужесточения условия число
   в отчёте не изменилось — подозревайте, что условие не применилось.
4. **Функция сжатия пробелов съедает SQL-комментарии.** Схлопнув запрос в одну
   строку, она уводит в `--` всё до конца запроса: условие молча выключается,
   запрос остаётся верным и отрабатывает. Комментарий к такому запросу ставьте
   комментарием языка НАД текстом, а не внутри SQL.
5. **Пустой ответ не затирает собранное.** Потеря обновления дешевле потери
   данных.
6. **Не требуйте инструментальных зависимостей из кода, который грузится в бою.**
   Парсер SQL нужен только разработчику; если его `require` стоит в файле,
   который приложение загружает при старте, боевой образ без этой зависимости не
   поднимется. Грузите по требованию и переживайте отсутствие: без парсера индекс
   просто беднее.
7. **Сортировка зависит от локали.** Первое сравнение двух списков имён дало
   мусор — имена оказались в обеих сторонах разом. Любое сличение — с
   фиксированной локалью.
8. **Приставка шарда — не таблица.** Прежде чем верить строке «таблицы нет в этой
   среде», проверьте, не приставка ли это: код может ходить в `t_0…t_N`, которые
   есть везде, а в индекс попала догадка `t`.
9. **Одно имя — одна строка на файл.** Строка на каждое вхождение даёт сотни
   тысяч рядов и ровно столько же пользы, сколько одна.
10. **Невалидный UTF-8 приходит из парсера.** Чистите каждый текст, иначе запись
    в базу падает на случайном файле.
11. **Прерванный разбор не оставляет половины.** Удаление и вставка записей файла
    — в одной транзакции.
12. **Тесты на разборщик — не роскошь.** Правила тонкие и ломаются молча: отчёт
    продолжает печататься, просто с другими числами. Полсотни примеров на
    фикстурах, каждый из которых закрывает уже случившуюся ошибку.
13. **Общий рабочий каталог.** Если в дереве работают несколько процессов,
    коммитьте по путям и никогда не прячьте изменения в стек.
14. **Байты снаружи — ещё не текст.** Вывод команды, значение из окружения,
    аргумент и строка лога помечаются кодировкой ЛОКАЛИ. Без неё это US-ASCII, и
    первая же нелатинская буква роняет `split`, `match?` или `format` — падает
    не находка, а ВСЯ команда, и читается это как «инструмент сломан». Две
    тонкости, каждая стоила проверки: `Encoding.default_external` НЕ чинит
    окружение и аргументы (их метит локаль, а она после запуска не меняется —
    лечится перезапуском процесса с `LC_ALL=C.UTF-8`), а смена ярлыка не чинит
    СОДЕРЖИМОЕ — настоящий битый байт остаётся, и нужна чистка. Точка входа,
    которая не грузит каркас приложения, не получает и его настройки кодировки:
    у нас так молча не работали две команды из двадцати семи, и это нашлось
    опытом (`env -u LANG …` на каждой), а не чтением.
15. **`rescue` вокруг обхода файлов прячет не ошибку, а данные.** Классический
    вид: `File.foreach … rescue ArgumentError; next`. Один битый байт в середине
    файла — и остаток файла не прочитан, при зелёном ответе. У нас на этом
    монитор ошибок отвечал «ни одной», прочитав лог до первого такого байта.
    Если глушить приходится, печатайте счёт пропущенного.
16. **В новом слое ложных находок больше, чем настоящих — в два-три раза.**
    Замер по семи разрядам: 137 сломанных примеров → 7, 632 битые ссылки → 15,
    25 дефектов `rewrite` → 2, 22 пропуска перевода → 6, 13 обращений к
    несуществующей колонке → 4, 3 мёртвых контроллера → 1. Ни один отсев из тех,
    что сократили эти числа, нельзя было придумать заранее — их видно только на
    находках. Поэтому: находку проверяют у первоисточника ПРЕЖДЕ, чем она
    попадёт в отчёт человеку; результат проверки хранят рядом с находкой, а не в
    сообщении коммита; и рядом с разрядом печатают долю ложных в нём — иначе все
    находки читаются одинаково весомо, а они не равны. Подробно — VI.3.
17. **Слой, которого нет в обходе, не молчит — он ВРЁТ.** Ложная находка это
    шум; отсутствующее расширение файла это другое: разборщик видит половину
    связки и уверенно докладывает о дефекте. В проекте на TypeScript
    `.ts/.tsx` не было в списке расширений, и отчёт выдал шесть находок
    «контроллер не зарегистрирован» и «метода нет» при существующих регистрации
    и методах. Признак такой поломки — НОЛЬ в счётчике слоя (ноль контроллеров,
    ноль ключей из шаблонов, ноль классов): ноль в самодиагностике проверяйте
    первым делом, он почти никогда не правда.
18. **Связь по СОГЛАШЕНИЮ называйте вслух.** Там, где ссылки нет, а связь всё
    же нужна, её приходится выводить из уговора: имя пака совпадает с именем
    файла входа, помощник подключается фреймворком по имени каталога, задача
    крона зовётся как класс. Такая связь — не факт и не догадка, а третье: она
    верна, пока уговор держат. Печатайте «по имени файла» рядом со строкой, и
    тогда расхождение читается как расхождение, а не как поломка инструмента.

---

# Часть VIII. Тесты: что утверждать

Фикстурные примеры на разборщик. Список — минимальный набор, ниже которого
инструмент начинает молча врать. У нас их 291 в двадцати файлах, выполняются за
2,5 с, и первый же прогон нашёл двойную запись, из-за которой счёт вызовов был
завышен вдвое. Правило отбора одно: **пример появляется из случившейся ошибки**,
а не из желания покрыть ветку. Поэтому у каждого примера есть комментарий «что
он однажды поймал» — без этого через месяц непонятно, можно ли его править.

**Разобранный SQL:** таблица и колонка вынуты; колонка привязана к таблице;
ключ внутри json-поля вынут вместе с полем.

**Подстановка:**
- имя таблицы, собранное на лету, НЕ попадает в факты; попадает в слепые зоны;
  приставка попадает в догадки;
- у записи есть выражение, корень и место в запросе;
- `in (…)` опознаётся и для второго элемента списка, не только для первого;
- различаются значение, кавычки и целое условие;
- строки, склеенные переносом, разбираются как ОДИН запрос: таблица найдена,
  слепых зон нет, места подстановок правильные;
- у каждой подстановки своя строка, а не начало литерала.

**Обрывки:**
- дыра в куске условия записывается с пометкой;
- строка лога и параметры адреса обрывком НЕ считаются;
- без сильного признака SQL обрывок не берётся, с признаком — берётся.

**Объявления:**
- все четыре способа задать видимость дают верный результат (девять методов —
  девять ожиданий);
- методы класса, объявленные блоком, помечены как методы класса;
- «возвращает предложение», «возвращает обрывок» и «в теле есть запрос» —
  три разных признака на трёх разных методах;
- параметры записаны.

**Обёртки колоночной базы:** таблицей считается первый аргумент ТОЛЬКО у обёрток
из явного списка; динамическое имя даёт выражение и узор, а не таблицу.

**Отрисовка:** старая форма с хвостовой стрелкой видна; обе ветки тернарного
выражения видны; интерполированное имя даёт узор; имя целиком в переменной даёт
слепое место; комментарии и текст страницы отрисовкой не считаются; логическое
имя шаблона собрано верно.

**Кандидаты:** имя из базы в тексте даёт один ряд с верным счётчиком; колонка из
аргументов ORM привязана к таблице модели; переменная, которой присвоили запрос,
записана вместе со значением и с дописанными кусками.

**Поиск вызовов** (на настоящих файлах во временном каталоге):
- объявление не считается вызовом;
- названы файл, строка, окружающий метод и аргументы;
- шаблон: номера строк совпадают с файлом; ветвление по разным тегам разобрано;
  комментарий шаблона не читается;
- динамический вызов с именем-литералом считается вызовом и отдаёт остальные
  аргументы; имя, собранное на лету, считается отдельно и вызовом не называется;
- символ — такая же зацепка, как вызов, и НЕ даёт второй записи рядом с вызовом;
- упоминания вне вызовов разобраны по разряду, и объявление в них не попало.

**Стили:** `&-big` внутри `.btn` объявляет `btn-big`; имя из комментария классом
не считается; `@apply` — использование; `@import 'base/reset'` находит
`_reset.scss`; ссылка на пакет отличается от битой; медиа-условие селектором не
считается, а его тело разбирается.

**Javascript:** голова объявления вызовом не считается; `...fn()` считается
вызовом; `_(` внутри регулярки и внутри шаблонной строки вызовом НЕ считается, а
`${build(x)}` — считается; вход сборки, собранный `path.join`, найден; привязка
импорта записана вместе с числом упоминаний.

**Журнал вердиктов:** у каждого разряда реестра есть выражение предмета, и оно
ОДНО — спека сверяет, что отсев и перечисление берут его из одного места
(разойдись два написания — вердикт молча перестанет узнавать свою находку);
вердикт «ложная» убирает находку из выборки; правка файла-якоря возвращает её.

**Кодировка:** значение из окружения с нелатинскими буквами не роняет команду;
вывод внешней команды чистится; самопроверка без локали проходит. Сторож
доказывается СНЯТИЕМ: уберите чистку — пример должен упасть.

**Ворота обхода:** изменившийся файл не пропускается (ошибка в опасную сторону —
отвечать по старому содержимому и выглядеть свежим); смена входов разбора
(схема, повадки) вызывает переразбор при неизменных файлах; возврат правки
замечается.

**Запросы внутри самих отчётов:** в сжимаемых (`squish`) запросах нет ни одного
`--`. Это не вкус: комментарий внутри такого запроса уводит в `--` всё до конца
строки, и у нас так молча выключился `group by`, а команда упала посреди работы.
Сторож проверен снятием.

Отдельная ловушка в самих тестах: если фикстура написана литералом с
интерполяцией, подстановка выполнится В ТЕСТЕ, разборщик получит строку без
дыры, и пример пройдёт по неверной причине. Пишите фикстуры литералами без
интерполяции.

---

# Часть IX. Порядок работ

Польза приходит быстрее всего в таком порядке:

1. **Схемы всех сред по отдельности** + отчёт о расхождениях. Полдня, и уже
   находит то, о чём никто не знал.
2. **Разбор SQL настоящим парсером** + «где трогают эту таблицу/колонку» с
   разделением факт/кандидат. Главный слой.
3. **Факты у запущенного приложения.** Почти бесплатно, связывает всё остальное.
4. **Инкрементальность** по контрольным суммам, чтобы запрос догонял индекс сам.
   После этого инструментом начинают пользоваться.
5. **Тесты на разборщик** — до того, как правил станет много.
6. Дальше по потребности: место исполнения, подстановки, логи боя,
   неиспользуемое, задетое правкой, архитектурные защёлки.

Холодный старт:

```sh
bin/rails xref:init     # создать базу индекса и накатить её схему
bin/rails xref:schema   # снять схемы всех источников
bin/rails xref:app      # факты у запущенного приложения
bin/rails xref:places   # состав служб с живых контейнеров
bin/rails xref:code     # разобрать дерево (первый проход — минута)
bin/rails xref:json     # ключи внутри бесхемных полей
bin/rails xref:views DATE=…   # логи за день; копить по дням
```

Дальше — то, что запускает ЧЕЛОВЕК, а не догон: оно читает боевые данные.

```sh
bin/rails xref:sql DATE=…         # узоры выполненных запросов из логов
bin/rails xref:sql_profile DAYS=30 # то же из статистики базы: окно неделями
bin/rails xref:fill TABLE=…        # сплошной проход по данным одной таблицы
```

Зависимости: разбор кода идёт ПОСЛЕ снятия схем (без имён из базы не будет
кандидатов) и ПОСЛЕ фактов приложения (без моделей обращения через ORM не
привязать к таблицам).

**Раскладка файлов.** Каждый файл отвечает за один слой и делается отдельно от
остальных; сборщики ничего не печатают, отчёты ничего не разбирают.

| Файл | За что отвечает |
| --- | --- |
| `config/xref.yml` | единственный источник правды: хранилище, источники, повадки дерева, логи, правила |
| `lib/xref.rb` | чтение конфига, повадки, приведение байтов к UTF-8 |
| `lib/xref/store.rb` | схема индекса, все представления и вся запись в него |
| `lib/xref/schema_source.rb` | снятие схемы одного источника, транспорты |
| `lib/xref/code_scanner.rb` | разбор одного файла — единственное место, которое знает про виды записей |
| `lib/xref/scan_plan.rb` | ворота обхода: что разбирать и у чего считать SHA |
| `lib/xref/call_sites.rb` | места вызова и упоминания по требованию (обёртка над поиском) |
| `lib/xref/text_search.rb` | поиск по тексту: один движок на все отчёты |
| `lib/xref/erb.rb` | сборка ruby из шаблона — ОДНА на весь индекс |
| `lib/xref/css.rb` | таблицы стилей: селекторы, `@import`, `@apply` (IV.18) |
| `lib/xref/js.rb` | javascript: модули, Stimulus, функции, привязки библиотек (IV.19) |
| `lib/xref/markdown.rb`, `nginx.rb`, `shell.rb`, `structured.rb` | слои за пределами кода: документы, фронт, оболочка, настройки |
| `lib/xref/locales.rb` | ключи переводов из файлов, помимо библиотеки |
| `lib/xref/db_sql.rb` | тела правил, триггеров и функций — тем же разборщиком SQL |
| `lib/xref/rails_facts.rb` | факты у запущенного приложения |
| `lib/xref/run_places.rb` | состав служб с живых контейнеров |
| `lib/xref/env_keys.rb`, `migrations.rb` | имена ключей среды и применённые миграции |
| `lib/xref/json_keys.rb` | ключи внутри бесхемных полей |
| `lib/xref/view_runtime.rb` | разбор боевых логов на узле (отрисовки и действия) |
| `lib/xref/sql_runtime.rb` | узоры выполненных запросов из логов |
| `lib/xref/sql_profile.rb` | те же узоры из статистики самой базы (IV.15) |
| `lib/xref/data_facts.rb` | заполненность колонок и сканирования индексов по живым данным |
| `lib/xref/verdicts.rb` | реестр разрядов находок и журнал проверок (VI.3) |
| `lib/xref/rules.rb`, `components.rb` | архитектурные правила с защёлкой и компонентная модель |
| `lib/tasks/xref.rake` | задачи и все отчёты (41 задача) |
| `bin/xref`, `bin/xref-run` | обёртка и быстрая точка входа без полного каркаса |
| `spec/lib/xref/` | 304 примера: разборщики, ворота, поиск, кодировка, журнал |

## Чего не делать

**Не пишите второй разборщик схемы.** Дамп грузите в базу и снимайте запросом.

**Не стройте граф вызовов с разрешением получателя** на большом динамическом
коде. Он даст уверенность, которой не заслуживает. Разбор по требованию по
названным именам — честнее и в сто раз дешевле. Поиск по целым словам и
фиксированной строке; если имён сотни, поиск встроенными средствами системы
контроля версий не укладывается в разумное время — одно объединённое выражение и
один проход по файлам быстрее на порядки.

**Не включайте в бою тяжёлую диагностику** ради инструмента анализа. Если
сборщик статистики запросов требует перезапуска боевой базы — это несоразмерно;
логи дают почти то же бесплатно.

**Не пытайтесь угадать то, что можно спросить.** Роуты, модели, расписание — у
приложения. Состав служб — у живых контейнеров. Содержимое бесхемных полей — у
данных.

---

# Часть X. Что останется неизвестным — и как это мерить

Раздел, без которого всё остальное опасно. Инструмент, чьи белые пятна не
посчитаны, читают как карту без белых пятен — и идут по ней уверенно.

**«Слепое место» значит три разные вещи, и держать их в одном счёте нельзя.**
Пока мы держали, счёт был вдвое больше настоящего:

1. **настоящая слепота** — «тут запрос (или ключ, или шаблон), и мы не знаем
   какой»;
2. **разрешённое** — имя собрано из переменной, но переменная присвоена рядом:
   ответ есть, и держать это в счёте незнания — врать про себя;
3. **кусок или текст** — строка обрывается на полуслове либо это фраза, начавшаяся
   с ключевого слова. Не знать там нечего.

Печатайте три числа врозь в самодиагностике. У нас после разделения и шести правок
разбора осталось 317 настоящих слепых мест вместо 731; 52 ушли в «разрешённые», 141
в «куски». Сейчас, после ещё одной найденной причины молчания (ниже, про номер
строки в heredoc): **280 настоящих** — 255 запросов и 25 обращений к колоночной
базе, — **86 «разрешено по присваиванию»** и **142 «кусок или текст»**. Числа
почти не двинулись не потому, что разбор перестал улучшаться, а потому, что
дерево в разборе за то же время выросло с 8 до 21,5 тысячи файлов: слепота
считается по всему, что инструмент начал видеть.

**Разряды настоящей слепоты, в порядке размера.** Числа наши, но важен не их
размер, а то, что каждый разряд назван и посчитан:

| разряд | у нас | чего именно не знаем |
| --- | --- | --- |
| **имя класса стиля на лету** | **2 421** | какое правило применится. Ещё 287 дают узор → кандидаты. Самая крупная слепая зона инструмента целиком |
| собранный ключ перевода | 420 обращений, 139 узоров | какой текст покажется — но у 94 узоров хранилище даёт ОТВЕТ: «один из ≤20 ключей». Слепыми остаются 42 широких и 3 с короткой приставкой |
| ключ-переменная у строки-ответа | 175 | какую колонку берут. Было 1 956, пока не проверялся ПОЛУЧАТЕЛЬ; у 44 записей таблица теперь известна |
| `select *` | 696 мест, 150 таблиц | у 92 таблиц звезда **не прячет ничего** (замер, а не допущение); у 58 остаётся |
| запрос с неразрешимой подстановкой | 255 (+25 у колоночной базы) | это уже ПОСЛЕ разрешения по присваиванию (86 мест). Дыр в позиции имени таблицы 154; треть таких мест — в одноразовых миграциях |
| имя шаблона на лету | 308, из них слепых 181 | какой партиал нарисуется. 127 дают УЗОР → кандидаты; из слепых 77 закрылись, когда узором стал и помощник контура с литералом |
| имя контроллера или цели Stimulus собрано | 52 | какой контроллер включает эта разметка; связь не прослежена |
| имя пака собрано | 3 | какой набор стилей и скриптов получит страница |
| вызов в javascript — ТОЛЬКО по имени | 8 091 вызов на 4 361 функцию | кого именно зовут: получатель не разрешается. Это решение (часть IX, «не стройте граф вызовов с разрешением получателя»), но в пределы его записать обязаны |

**Сверка по НОМЕРУ СТРОКИ — худший способ связать две записи об одном запросе.**
Запись «имя таблицы собрано целиком» ставится на строку начала запроса, а запись
о самой подстановке — на строку, где эта подстановка стоит. В запросе из heredoc
(а это самый частый способ писать SQL) они не совпадают никогда, и разрешение по
присваиванию не срабатывало ВООБЩЕ: из 166 таких мест ни одного, при том что
`TABLE = '…'` стоит в том же файле, строкой выше. Лечится не расширением
допуска, а переносом знания: корень дыры записывает сам разбор запроса, который
обе записи и создаёт. У нас это 34 слепых места, ставших фактами, и девять
имён таблиц, которых индекс не знал вовсе (`identity_audit_events`,
`events_log2`, `partner_stat_common`).

**Слепое место, у которого ответ лежит в ваших же данных, — не слепое.** Самое
крупное из названных (обращения к переводу по собранному ключу) оказалось таким
наполовину: узор `user_notifs.L$1` — это не «неизвестно что», а «один из
`user_notifs.Lmen`, `user_notifs.Lwomen`», и хранилище текстов это знает. Сверка
узоров с хранилищем дала ответ у 94 узоров из 139 — и одну НАХОДКУ, которой
статически было не видно вовсе: узор `month.m$1` не совпал ни с одним ключом,
потому что пространство называется `months`, и заголовок экрана печатал
«translation missing».

Две ловушки этой сверки, обе мои собственные и обе найдены замером:

- **приставку и хвост берите ВОКРУГ дыры, а не склейкой куска до и после.**
  Склейка `pitest.scales.scale_$1.expl.$1` → `pitest.scales.scale.expl.` не
  совпадает ни с чем, и так я намерил 36 «узоров без совпадения» вместо одного;
- **`like приставка || '%'` для ключей не годится**: в именах ключей подчёркивание
  сплошь, а в LIKE оно подстановочный знак. Нужно сравнение приставки как
  текста (`starts_with`), иначе `payments.subscr_%` совпадает с
  `payments.subscrXxx`.

**Проверяйте ПОЛУЧАТЕЛЯ, прежде чем звать обращение по переменной слепым местом.**
`что-то[переменная]` в ruby — это и чтение колонки, и обращение к массиву, и
файловый глоб. Пока мы не различали, счёт собственного незнания был завышен в
двенадцать раз: 1 956 вместо 156. Это худший вид ошибки — она делает инструмент
скромнее, чем он есть, и обесценивает настоящие находки. Признак получателя:
переменная, которой присвоили результат запроса, или имя, которое в этом дереве
всегда значит строку (`row`, `line`, `info`). Счёт при этом НИЖНИЙ, и так и
говорите: строка-ответ, названная необычно, в него не попадёт.

**А цикл по списку колонок — вообще не слепое место.**
`['a','b','c'].each { |key| row[key] }` читает ровно те колонки, которые в списке:
свяжите параметр блока с составом — список бывает прямо в цикле, объявлен в том же
файле или известен из прежнего разбора. У нас это 194 обращения, переставших быть
слепыми. Требуйте, чтобы ВСЕ элементы списка были известными именами колонок,
иначе в чтения попадёт любой цикл по словам.

**Покрытие — отдельный разряд, и его путают со слепотой чаще всего.** «Не мерили»
и «не знаем» — разные ответы, и первый лечится прогоном:

- **файлы вне разбора вовсе**: у нас это было 15 тысяч из 23 337, и молчание про
  них читалось как «там ничего нет». После семи разборов (документы, настройки,
  скрипты, конфиги фронта, javascript, TypeScript, стили) вне разбора осталось
  **1 826 из 23 411**: картинки, шрифты и поставляемые зависимости. Это уже не
  молчание, а названный список;
- **и внутри разобранного слоя остаётся не прочитанное содержимое**: стили из
  `node_modules` не читаются (поэтому «правила нет ни в одном НАШЕМ стиле» для
  класса библиотеки не значит ничего), внутрь пакетов javascript не заходим
  намеренно (IV.19), тела функций на процедурном языке базы не разбираются
  (IV.1). Это не слепота разбора, а объявленная граница — но в отчёте она должна
  стоять рядом с ответом, иначе читается как вывод;
- файлы вне графа ссылок: у нас это 1 037 файлов приложения. Одним числом
  читается как «тысяча мёртвых файлов», и это неправда почти целиком — поэтому
  разряды обязательны: **рисовались в бою, а граф не видит** (53 — недобор
  ГРАФА, не смерть файла), шаблоны без наблюдения (666 при окне одиннадцать
  суток), javascript (42 — корни сборки и самостоятельные скрипты, их не
  импортирует никто по построению), ссылка есть, а пути нет (170), **помощники**
  (64 — фреймворк подключает их неявно, по имени их не зовут никогда), без
  константы в описи (7 — искать нечем), и только **35** — «ни одной ссылки по
  имени», то есть кандидаты на снятие.
  И оговорка в подписи обязана считаться ИЗ ДАННЫХ: вшитое «окно наблюдения
  сутки» пережило у нас рост окна до одиннадцати суток и печаталось неправдой
  рядом с верным числом — поймано при вычитке отчёта, а не прогоном;
  Две тонкости счёта, каждая давала ложные кандидаты: опись приложения даёт ОДНО
  имя на файл (а у нас есть файл на 735 КБ с девяноста двумя модулями — проверять
  надо все, что он объявляет), и вид записи называется `const_ref`, а не `const` —
  ошибка в имени вида объявила кандидатами 272 файла вместо 35;
- **цепочка, доказуемая не везде**: вопрос «есть ли правило для этого класса в
  ЭТОМ контуре» (IV.18) требует, чтобы макет называл пак. У нас таких деревьев
  шаблонов три; про остальные **2 376 классов** слой молчит — и говорит, что
  молчит, а не отвечает «правила нет»;
- замер живых данных: сделан у 28 таблиц (820 колонок) из восьмисот с лишним —
  три процента; остальные «не мерили». И запускается он человеком, поэтому
  покрытие само не растёт;
- **окно наблюдения** — печатайте его рядом с каждым «в бою не трогали», иначе
  утверждение нечитаемо: за одни сутки не трогали и за сто суток не трогали
  отличаются всем, а выглядят одинаково. Сутки НЕ затираются друг другом, и окно
  растёт само с каждым сбором; срезайте только хвост за N суток, иначе через год
  в таблице полтора миллиона строк ни на чей вопрос.

  И честное наблюдение про ширину этого окна, потому что интуиция тут обманывает.
  Мы ждали, что второй день покажет много нового, — он показал **ноль**: ни одной
  новой таблицы, ни одной новой колонки, и всего 18 новых узоров запроса из 353.
  По составу таблиц и колонок суточное окно оказалось насыщенным, и расширять его
  стоит не ради покрытия, а ради РЕДКОГО: недельный и месячный крон в сутки не
  попадает вовсе, и ловится он неделями наблюдения, а не вторым днём;
- узоры из логов режутся по длине: у нас 744 из 8 475 не разобрались;
- **окно у источников РАЗНОЕ, и общего числа тут нет.** Сбор из статистики базы
  (IV.15) настроен у нас на одном источнике из трёх: там окно восемь суток, у
  остальных двое. Печатайте по источнику врозь — «в бою не трогали» с разным
  окном это разные утверждения;
- файлы без компонента: 13 479 из 21 585 (62 %) — архитектурные правила их не
  видят. Почти вся эта масса — машинные описи в `doc/` (одна папка на шесть
  тысяч файлов), и именно поэтому число надо печатать с раскладкой по каталогам:
  одним числом оно читается как «модель описывает треть дерева», а по
  каталогам — как «модель описывает код, а не описи»;
- ключи окружения, которые читает не ruby (nginx, оболочки, сам контейнер): 144.
  Проверить их этим инструментом нечем.

**Структурные пределы — то, чего этим способом не узнать вовсе.** Их надо
перечислить честно, иначе каждый следующий читатель будет заново надеяться:

- `method_missing`, `send` с именем, собранным на лету, `define_method`,
  `respond_to?`;
- обращения через ORM-ассоциации: `user.photos.each` имени таблицы не называет;
- значение переменной времени выполнения — какой шард выбран. Логи закрывают это
  частично и только для того, что выполнялось в собранные сутки;
- метод, возвращающий запрос из ветки условия, «возвращающим запрос» не считается:
  смотрится последнее выражение тела;
- обрывок запроса берётся только с сильным признаком SQL — подстановка значения в
  `"a=#{b}"` в индекс не попадёт, и это плата за отсутствие шума из строк лога.

**Как мерить всё это одним прогоном.** Самодиагностика должна печатать: три числа
слепоты, разряды по видам записей, покрытие (файлы в графе, таблицы с замером,
окно наблюдения) и отдельно — счётчики, по которым видно поломку самого разбора
(у нас это «обращений по ключу из шаблонов»: ноль там значит, что разбор шаблонов
сломан, а не что обращений нет).

---

# Честный итог

Ценность такого индекса не в том, что он находит больше человека. Проверка на
настоящей задаче: из двадцати девяти затронутых файлов двадцать восемь были
найдены и вручную, тремя раундами чтения. Ценность в том, что **он находит это за
секунду вместо трёх раундов** — и что двадцать девятый он всё-таки нашёл.

И в том, что он называет свои границы. Карта, которая молчит о белых пятнах,
опаснее отсутствия карты: по ней идут уверенно.
