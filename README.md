# MTS Engineer Hack - воспроизводимый DevOps-стенд

## 1. Назначение решения

Репозиторий разворачивает локальный Kubernetes-стенд: Nginx с входом через
Envoy Gateway и Gateway API, Prometheus с реальными целями сбора метрик,
Fluentd для доставки журналов доступа и ошибок Nginx в Loki. Приложение задаётся
только конфигурацией Nginx. Все ресурсы, версии и проверки находятся в репозитории.

Для стенда выбран kind вместо kubeadm; kind разрешён условиями задания.
Проверенная среда хоста - Ubuntu 24.04.5 в WSL2. Сам узел kind работает на Debian.
Проверки воспроизводят запросы через шлюз, выполняют PromQL и ищут новые записи
в Loki; готовность Pod сама по себе не подтверждает работу приложения.

## 2. Архитектура

Логический маршрут: пользователь → Envoy Gateway → Gateway API → HTTPRoute → Nginx.
Envoy Gateway управляет шлюзом по декларациям Gateway API. Реальный HTTP-трафик
проходит через созданный контроллером прокси Envoy:

```text
Пользователь (Host: mts.local)
  → локальный port-forward :8080
  → Service прокси Envoy :80
  → Gateway mts-gateway / HTTPRoute nginx-demo
  → Service nginx-demo :80 → Nginx :8080

Prometheus → /metrics самого Prometheus и Loki
Nginx → access.json / error.log → Fluentd (sidecar) → Loki
```

GatewayClass `mts-envoy` связывает Gateway с контроллером. EnvoyProxy `mts-proxy`
фиксирует образ прокси и тип Service `ClusterIP`. HTTPRoute принимает hostname
`mts.local`, путь с префиксом `/` и направляет его на `nginx-demo:80`.
Service прокси определяется по меткам владельца Gateway; отсутствие или
неоднозначный результат приводят к ошибке.
Пространства имён: `envoy-gateway-system` для контроллера и прокси, `mts-app` для
Nginx, Fluentd и маршрутизации, `mts-observability` для Prometheus и Loki.

## 3. Используемые технологии и версии

Источник версий и полных SHA-256 образов - [config/versions.env](config/versions.env).

| Компонент | Зафиксированная версия |
| --- | --- |
| Среда хоста, проверенная в WSL2 | Ubuntu 24.04.5, дистрибутив `Ubuntu-24.04` |
| kind | v0.33.0 |
| Kubernetes | v1.36.4 |
| kubectl | v1.37.0 |
| Envoy Gateway | v1.9.2 |
| Gateway API | v1.6.1 |
| Прокси Envoy | distroless-v1.39.1 |
| Nginx | 1.30.5-alpine |
| Prometheus | v3.15.0 |
| Fluentd | 1.19.4 |
| Базовый образ Fluentd | v1.19.3-debian-2.3 |
| Плагин Fluentd для Loki | 1.3.0 |
| Loki | v3.7.8 |

Образ узла взят из [релиза kind v0.33.0](https://github.com/kubernetes-sigs/kind/releases/tag/v0.33.0).
Разница kubectl и сервера составляет одну минорную версию;
[политика Kubernetes](https://kubernetes.io/releases/version-skew-policy/)
описывает допустимое расхождение. Для версии Envoy Gateway см.
[матрицу совместимости](https://gateway.envoyproxy.io/news/releases/matrix/).
Версия Gateway API проверяется по аннотациям CRD в сохранённом установщике.
Установщик включает экспериментальные CRD, но приложение использует стабильные
ресурсы Gateway API `v1`. Второй набор CRD Gateway API устанавливать не нужно.

База Fluentd содержит 1.19.3; Dockerfile устанавливает gem 1.19.4 и плагин 1.3.0
с проверкой SHA-256. Транзитивные зависимости закреплены в `Gemfile.lock`.
Локальный образ `mts-engineer/fluentd:1.19.4-loki1.3.0-r1` обозначает рецепт
сборки; скрипт проверяет метку рецепта и фактический digest конфигурации образа,
загруженного в kind. Это локальный образ с `imagePullPolicy: Never`.
Контроллер, certgen и shutdown manager используют один закреплённый образ Gateway.

Источники телеметрии: [Prometheus v3.15.0](https://github.com/prometheus/prometheus/releases/tag/v3.15.0),
[Loki v3.7.8](https://github.com/grafana/loki/releases/tag/v3.7.8),
[Fluentd 1.19.4](https://www.fluentd.org/blog/fluentd-v1.19.4-has-been-released/),
[метаданные gem для Linux](https://rubygems.org/api/v2/rubygems/fluentd/versions/1.19.4.json?platform=ruby),
[метаданные плагина](https://rubygems.org/api/v2/rubygems/fluent-plugin-grafana-loki/versions/1.3.0.json).
Работоспособность конкретной комбинации подтверждается проверками этого стенда;
это не заявление о поддержке любой версии Kubernetes каждым компонентом.

## 4. Требования к окружению

Windows с WSL2, Ubuntu 24.04 и Docker Desktop с интеграцией WSL и Linux-контейнерами
amd64. Нужны kind **v0.33.0**, kubectl **v1.37.0**, Docker CLI, Bash, curl,
Python 3 с PyYAML, OpenSSL, `timeout`, `sha256sum`, `flock`.
Для сборки без кеша требуется доступ к реестрам образов и RubyGems.
Установка инструментов хоста не входит в скрипты репозитория.

Перейдите в корень клона внутри WSL; все команды ниже выполняются оттуда:

```powershell
wsl -d Ubuntu-24.04
```

```bash
kind version
kubectl version --client
docker info --format '{{.OSType}}/{{.Architecture}}'
python3 -c 'import yaml; print(yaml.__version__)'
```

Автоматической проверке нужны свободные адреса `127.0.0.1:8080`, `:9090`, `:3100`.
Она создаёт временные перенаправления только на loopback и закрывает собственные
процессы при завершении, включая ошибку. Для телеметрии можно выбрать другие порты.

## 5. Создание Kubernetes-кластера с нуля

Этот шаг нужен только при отсутствии `mts-engineer`. Блок отказывается создавать
уже существующий кластер. Используются сохранённая конфигурация и точный образ
из файла версий. kind автоматически выбирает контекст создаваемого кластера;
обработчик выхода восстанавливает прежний контекст, в том числе после ошибки.

```bash
(
  set -euo pipefail
  source config/versions.env
  existing_clusters=$(kind get clusters)
  if grep -Fxq mts-engineer <<<"$existing_clusters"; then
    printf '%s\n' 'Кластер mts-engineer уже существует; используйте раздел 6.' >&2
    exit 1
  fi

  previous_context=$(kubectl config current-context 2>/dev/null || true)
  restore_context() {
    if [[ -n $previous_context ]]; then
      kubectl config use-context "$previous_context" >/dev/null
    else
      kubectl config unset current-context >/dev/null
    fi
  }
  trap restore_context EXIT
  kind create cluster --name mts-engineer --config kind/cluster.yaml \
    --image "$KIND_NODE_IMAGE" --wait 180s
)
```

Данные доступа сохраняются в файл, выбранный `KUBECONFIG`, либо в `~/.kube/config`.
Используйте то же окружение `KUBECONFIG` для дальнейших команд. Если до создания
контекст не был выбран, блок очищает поле `current-context` после завершения.
См. [работу с kubeconfig в kind](https://kind.sigs.k8s.io/docs/user/quick-start/#interacting-with-your-cluster).
Создание кластера - инструкция для новой среды; проверки релиза выполняются
на уже существующем совместимом кластере.

## 6. Использование уже существующего совместимого кластера

Пропустите создание, если `mts-engineer` уже существует. Требуется ровно один узел
`mts-engineer-control-plane` со статусом Ready, Kubernetes **v1.36.4** и точным
образом `KIND_NODE_IMAGE`. Bootstrap проверяет версии, Docker-метки, образ узла,
адрес API, имя контекста и готовность. Несовпадение нужно исследовать;
скрипты не удаляют и не заменяют кластер.

```bash
kubectl --context kind-mts-engineer wait --for=condition=Ready \
  node/mts-engineer-control-plane --timeout=180s
kubectl --context kind-mts-engineer version
kubectl --context kind-mts-engineer get nodes -o wide
```

Далее одинаково для нового и существующего кластера. Команды репозитория всегда
передают `--context kind-mts-engineer` и не меняют текущий контекст пользователя.

## 7. Подготовка

```bash
bash scripts/bootstrap.sh
```

Это проверка окружения и кластера без установки ресурсов. При успехе выводится
`Platform preflight passed`. Отсутствующий или несовместимый кластер вызывает ошибку.

## 8. Развертывание

```bash
bash scripts/deploy.sh
```

Сначала скрипт проверяет сохранённый установщик и локально формирует декларации.
Затем собирает Fluentd, проверяет образ и загружает его в kind. Порядок установки:
пространства имён → CRD → предварительные ресурсы → certgen → контроллер →
приложение, маршрутизация и телеметрия. Готовность ожидается с ограничением времени.

Существующий завершённый Job certgen повторно используется, если спецификация,
сертификаты и CA вебхука согласованы. Частичный или некорректный набор сертификатов
приводит к явной ошибке. ConfigMap имеют постоянные имена; контрольные суммы
конфигурации в шаблонах Pod обеспечивают обновление при изменениях.
Завершение `Deployment ready` означает готовность ресурсов; приёмка трафика
и данных выполняется следующей командой.

## 9. Проверка Gateway API и приложения

Полная проверка, включая маршрутизацию:

```bash
bash scripts/verify.sh
```

Требуются условия текущего поколения: GatewayClass `Accepted=True`, Gateway
и его HTTP-listener `Accepted=True` / `Programmed=True`, HTTPRoute
`Accepted=True` / `ResolvedRefs=True`. Тест обнаруживает ровно один прокси Service,
проверяет порт и направляет запрос через него. Для `GET /` с `Host: mts.local`
требуются HTTP 200, `Content-Type: text/plain` и точные байты:

```text
MTS Engineer Hack: OK
```

После `OK` обязательно присутствует LF. Для `Host: wrong.invalid` требуется
HTTP 404 от шлюза. Прямое перенаправление к Nginx не используется для приёмки.

Для ручного запроса запустите в первом терминале WSL:

```bash
source scripts/lib/common.sh
proxy=$(proxy_service)
kubectl --context kind-mts-engineer -n envoy-gateway-system \
  port-forward --address=127.0.0.1 "service/$proxy" 8080:80
```

Во втором терминале отправьте запрос с новым идентификатором:

```bash
RUN_ID="mts-$(date -u +%Y%m%dT%H%M%SZ)-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
curl --fail --show-error -H 'Host: mts.local' \
  -H "X-MTS-Request-ID: $RUN_ID-access" http://127.0.0.1:8080/
```

Закройте ручное перенаправление сочетанием Ctrl+C перед запуском `verify.sh`.

## 10. Проверка Prometheus

`verify.sh` открывает Prometheus на `127.0.0.1:9090`, проверяет `/-/ready`, затем
`/api/v1/targets` и `/api/v1/query`. Должны быть ровно две здоровые цели:

| Задание | Реальная цель `/metrics` |
| --- | --- |
| `prometheus` | `prometheus.mts-observability.svc.cluster.local:9090` |
| `loki` | `loki.mts-observability.svc.cluster.local:3100` |

Период сбора - 15 секунд, тайм-аут - 5 секунд. Запросы `up{job="prometheus"}`,
`up{job="loki"}`, `prometheus_build_info{job="prometheus"}` должны вернуть по одному
элементу вектора со значением **1**. Версия в `build_info` сравнивается с pin.
Пустой успешный ответ не проходит проверку. Nginx exporter не установлен:
метрики приложения этим стендом не собираются.

## 11. Проверка логирования

Nginx записывает JSON-журнал доступа в `/var/log/nginx/access.json`, нативные ошибки
в `/var/log/nginx/error.log`. Fluentd читает общий `emptyDir` только для чтения,
ведёт отдельные позиции и ограниченные файловые буферы в `/fluentd/state` и
доставляет JSON-записи в Loki. При отказе HTTP-отправки буфер сохраняется для повтора.
Фиксированные метки потока: `namespace=mts-app`, `app=nginx-demo`, `container=nginx`,
`collector=fluentd`, `log_type=access|error`. Идентификаторы запросов остаются
полями записи и не повышают кардинальность меток.

Каждый запуск `verify.sh` создаёт свежий `RUN_ID` и задаёт окно запросов Loki:

1. Отправляет `GET /` через Gateway с `X-MTS-Request-ID: <RUN_ID>-access`.
2. Ищет в `/loki/api/v1/query_range` новую запись доступа с этим ID, статусом 200,
   методом GET, путём `/`, хостом `mts.local`, именем Pod и путём файла-источника.
3. Отправляет `GET /error/<RUN_ID>-error` с соответствующим заголовком и получает 404.
4. Требует новую запись доступа 404 и настоящую ошибку Nginx `open() ... failed ...
   No such file or directory`, содержащую этот URI. Это обработка отсутствующего
   статического файла, а не синтетическое сообщение или директива `return 404`.
5. Сравнивает найденные события с файлами исходного Pod и проверяет образ,
   конфигурацию и готовность Fluentd.

Нативная ошибка не содержит пользовательский заголовок, поэтому связывается по
уникальному URI. Проверка не отправляет данные напрямую в Loki. Исторические
журналы и диагностический вывод Fluentd не заменяют новые записи приложения.

## 12. Полная автоматическая проверка

```bash
bash scripts/verify.sh
# При занятых портах телеметрии:
bash scripts/verify.sh --prometheus-port 19090 --loki-port 13100
```

В успешном выводе присутствуют `root=200 exact; missing-file=404; wrong-host=404`,
`PASS Prometheus`, `PASS Loki`, `PASS Nginx producer files` и `Acceptance passed`.
Для каждого вида журнала требуется ненулевое количество совпадений.
Детальные ответы API и журналы перенаправлений сохраняются только локально в
игнорируемом каталоге `.local/verify/<RUN_ID>/`. Они не публикуются в Git.

Статические проверки можно выполнить без развертывания:

```bash
find scripts tests images -type f -name '*.sh' -print0 \
  | while IFS= read -r -d '' file; do bash -n "$file"; done
bash tests/platform.sh --static
bash tests/gateway-app.sh --static
bash tests/observability.sh --static
kubectl --context kind-mts-engineer kustomize kubernetes >/dev/null
git diff --check
```

Проверяются YAML, версии и SHA-256, уникальность ресурсов, композиция Kustomize,
конфигурации, безопасные границы очистки и отклонение устаревшего статуса Gateway.
Статические проверки не подтверждают прохождение HTTP-запросов и доставку данных.
Каждый скрипт поддерживает `--help`; ошибочные аргументы завершаются ненулевым кодом.
При ошибке начните с вывода проверки и локальных файлов соответствующего запуска.
Занятый порт вызывает явную ошибку. Изменение рецепта Fluentd под прежним тегом
отклоняется: измените суффикс ревизии одновременно в файле версий и манифесте.
Полный вывод API, сертификаты и данные доступа нельзя добавлять в репозиторий.

## 13. Повторное развертывание

```bash
bash scripts/deploy.sh
bash scripts/verify.sh
```

Повторное применение сходится к тем же декларациям без дублирования ресурсов.
При неизменных конфигурации и рецепте используются прежние ресурсы и совместимый
завершённый certgen Job. Приёмка после каждого развертывания использует новые ID.
Последовательность повторного развертывания и проверки испытана на этом стенде.

## 14. Очистка

```bash
bash scripts/destroy.sh
```

Удаляются только разрешённые ресурсы приложения, маршрутизации и телеметрии,
включая проектный GatewayClass, после проверки меток владения. Скрипт ожидает
удаления Deployment и Service прокси, созданных контроллером. Завершение удаления
зависимых Pod может произойти немного позже при сборке мусора Kubernetes.

Сохраняются **кластер kind**, три пространства имён, CRD, контроллер, сертификаты,
RBAC платформы и посторонние ресурсы. Режима удаления кластера нет.
Для восстановления выполните `bootstrap.sh`, `deploy.sh`, `verify.sh` в этом порядке.

## 15. Структура репозитория

| Путь | Содержимое |
| --- | --- |
| `README.md` | Архитектура, команды воспроизведения, приёмка и ограничения |
| `config/versions.env` | Версии, образы и контрольные суммы |
| `kind/cluster.yaml` | Декларация одноузлового кластера |
| `images/fluentd/` | Dockerfile, закреплённые gems, обработка повторов и её тест |
| `kubernetes/app/` | Конфигурация Nginx и базовые ресурсы приложения |
| `kubernetes/gateway/` | GatewayClass, Gateway, HTTPRoute и EnvoyProxy |
| `kubernetes/observability/` | Prometheus, Loki, Fluentd и наложение sidecar |
| `kubernetes/platform/` | Пространства имён |
| `kubernetes/vendor/envoy-gateway/v1.9.2/` | Установщик, локальные фазы, источник и SHA-256 |
| `kubernetes/kustomization.yaml` | Итоговая композиция ресурсов |
| `scripts/` | Подготовка, установка, проверка, очистка и вспомогательные функции |
| `tests/` | Статические проверки и проверки работающего стенда |
| `.gitignore`, `.gitattributes` | Исключения локальных файлов и правила окончаний строк |

## 16. Дополнительные реализованные практики

- Декларативные ресурсы, закреплённые версии и digest внешних образов.
- Проверка происхождения установщика, gems и фактически загруженного локального образа.
- Постоянные имена ConfigMap и детерминированные суммы для обновления Pod.
- Непривилегированные контейнеры приложения и телеметрии, корневая файловая система
  только для чтения, сброс capabilities, профиль seccomp, отключение API-токенов.
- Запросы и лимиты ресурсов, probes, ограниченные ожидания и блокировка
  одновременных `deploy` / `destroy` в одном клоне.
- Ограниченные буферы Fluentd, повтор отправки без намеренного удаления chunks,
  локальное обогащение меток без доступа к Kubernetes API.
- Проверка владельца перед очисткой и завершение только собственных port-forward.
- Корреляция свежих запросов, проверка исходных файлов Nginx и нативных ошибок.

## 17. Ограничения

kind вместо kubeadm, один узел и одна реплика каждого компонента. Используется
локальный HTTP без TLS для приложения, внешнего балансировщика и облачной интеграции.
Высокая доступность (HA) не реализована. Журналы, позиции и буферы Fluentd,
метрики Prometheus и данные Loki находятся в `emptyDir`; замена Pod или очистка
приводят к потере соответствующих данных. Постоянного хранилища наблюдаемости нет.
Аутентификация Loki отключена для локального стенда. Grafana, service mesh,
Terraform, Argo CD и дополнительные операторы не требуются и не установлены.
Результаты приёмки относятся к закреплённой проверенной среде.

## 18. Воспроизводимость

Проверяющему достаточно клонировать репозиторий, подготовить инструменты из раздела 4,
создать кластер по разделу 5 либо подтвердить совместимость по разделу 6, затем
выполнить `bootstrap.sh`, `deploy.sh`, `verify.sh`. Скрипты определяют корень
репозитория относительно собственного файла и работают из произвольного пути клона.

Внешние образы имеют теги версий и SHA-256; установщик Envoy Gateway хранится
побайтно с `source.env` и `install.sha256`. Его загрузка во время установки не нужна.
Модификации поверх установщика находятся в отдельных декларативных патчах.
Dockerfile проверяет SHA-256 gems, `Gemfile.lock` фиксирует зависимости.
Смена pin требует согласованного обновления потребителей и повторных статических
и живых проверок. Развертывание и приёмка используют сохранённые конфигурации;
диагностические файлы остаются локальными.
