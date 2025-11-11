#!/bin/bash

# Константы скрипта
PREFIX="resore_docker"
RESTORE_DIR="restore_docker"
DOCKER_COMPOSE_FILE="docker-compose.yml"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Функция для проверки наличия команд
check_commands() {
    local commands=("docker" "docker-compose" "tar")
    for cmd in "${commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Команда $cmd не найдена. Убедитесь, что Docker и tar установлены."
            exit 1
        fi
    done
}

# Функция для поиска docker-compose.yml
find_docker_compose() {
    if [[ -f "$DOCKER_COMPOSE_FILE" ]]; then
        log_info "Найден $DOCKER_COMPOSE_FILE в текущей директории"
        echo "$DOCKER_COMPOSE_FILE"
        return 0
    else
        log_warning "$DOCKER_COMPOSE_FILE не найден в текущей директории"
        read -p "Введите путь к $DOCKER_COMPOSE_FILE: " custom_path
        if [[ -f "$custom_path" ]]; then
            echo "$custom_path"
            return 0
        else
            log_error "Файл $custom_path не существует"
            exit 1
        fi
    fi
}

# Функция для получения списка образов из docker-compose.yml
get_images_from_compose() {
    local compose_file=$1
    local images=()

    # Получаем образы из services
    while IFS= read -r image; do
        if [[ -n "$image" ]]; then
            images+=("$image")
        fi
    done < <(docker-compose -f "$compose_file" images -q 2>/dev/null)

    # Альтернативный способ через парсинг yaml (более надежный)
    if [[ ${#images[@]} -eq 0 ]]; then
        while IFS= read -r image; do
            if [[ -n "$image" && "$image" != "null" ]]; then
                images+=("$image")
            fi
        done < <(docker-compose -f "$compose_file" config | grep "image:" | awk '{print $2}' 2>/dev/null)
    fi

    echo "${images[@]}"
}

# Функция для сохранения образов
save_images() {
    local compose_file=$1
    local output_dir=$2

    log_info "Получение списка образов из $compose_file..."
    local images
    IFS=' ' read -ra images <<< "$(get_images_from_compose "$compose_file")"

    if [[ ${#images[@]} -eq 0 ]]; then
        log_error "Не удалось получить список образов из $compose_file"
        exit 1
    fi

    log_info "Найдено образов: ${#images[@]}"
    for image in "${images[@]}"; do
        log_info "Обработка: $image"
    done

    # Создаем временную директорию
    local temp_dir
    temp_dir=$(mktemp -d)

    # Сохраняем docker-compose.yml
    cp "$compose_file" "$temp_dir/"

    # Сохраняем Dockerfile и контекст, если есть
    local build_context
    build_context=$(grep -A5 "build:" "$compose_file" | grep "context:" | head -1 | awk '{print $2}' | tr -d '"' || echo "")
    if [[ -n "$build_context" && -d "$build_context" ]]; then
        log_info "Копирование контекста сборки: $build_context"
        cp -r "$build_context" "$temp_dir/build_context"
    fi

    # Копируем init-db если есть
    if [[ -d "init-db" ]]; then
        log_info "Копирование init-db"
        cp -r "init-db" "$temp_dir/"
    fi

    # Сохраняем образы
    local images_dir="$temp_dir/images"
    mkdir -p "$images_dir"

    for image in "${images[@]}"; do
        local filename
        filename=$(echo "$image" | sed 's/[\/:]/-/g').tar
        log_info "Сохранение образа $image в $filename"

        if ! docker save -o "$images_dir/$filename" "$image"; then
            log_warning "Не удалось сохранить образ $image, пропускаем..."
        else
            log_success "Образ $image сохранен"
        fi
    done

    # Создаем скрипт для восстановления
    cat > "$temp_dir/restore.sh" << 'EOF'
#!/bin/bash

# Скрипт восстановления
echo "Восстановление Docker образов..."

# Создаем директорию для логов
mkdir -p logs

# Загружаем образы
if [[ -d "images" ]]; then
    for image_file in images/*.tar; do
        if [[ -f "$image_file" ]]; then
            echo "Загрузка образа: $image_file"
            docker load -i "$image_file" >> logs/load.log 2>&1
        fi
    done
    echo "Все образы загружены"
else
    echo "Директория images не найдена"
fi

# Запускаем docker-compose
if [[ -f "docker-compose.yml" ]]; then
    echo "Запуск docker-compose..."
    docker-compose up -d
    echo "Сервисы запущены"
else
    echo "docker-compose.yml не найден"
fi

echo "Восстановление завершено!"
EOF

    chmod +x "$temp_dir/restore.sh"

    # Создаем README
    cat > "$temp_dir/README.md" << EOF
# Восстановление Docker окружения

## Содержимое архива:
- docker-compose.yml - конфигурация сервисов
- images/ - Docker образы
- restore.sh - скрипт автоматического восстановления
$([[ -d "init-db" ]] && echo "- init-db/ - скрипты инициализации БД")
$([[ -n "$build_context" ]] && echo "- build_context/ - контекст для сборки кастомного образа")

## Инструкция по восстановлению:

1. Распакуйте архив в нужную директорию
2. Перейдите в распакованную директорию
3. Запустите скрипт восстановления:
   \`\`\`bash
   ./restore.sh
   \`\`\`

4. Или выполните вручную:
   \`\`\`bash
   # Загрузите образы
   for file in images/*.tar; do docker load -i \$file; done

   # Запустите сервисы
   docker-compose up -d
   \`\`\`

## Проверка работы:
\`\`\`bash
docker-compose ps
docker-compose logs
\`\`\`
EOF

    # Создаем архив
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")

    read -p "Введите название архива (без расширения): " archive_name
    if [[ -z "$archive_name" ]]; then
        archive_name="${PREFIX}_${timestamp}"
    else
        archive_name="${PREFIX}_${archive_name}_${timestamp}"
    fi

    local archive_path="${output_dir}/${archive_name}.tar.gz"

    log_info "Создание архива $archive_path..."
    tar -czf "$archive_path" -C "$temp_dir" .

    # Очищаем временную директорию
    rm -rf "$temp_dir"

    log_success "Архив создан: $archive_path"
    echo "Размер архива: $(du -h "$archive_path" | cut -f1)"
}

# Функция для поиска и предложения восстановления архивов
find_and_offer_restore() {
    local archives=()

    # Ищем архивы с префиксом
    while IFS= read -r -d $'\0' file; do
        archives+=("$file")
    done < <(find . -maxdepth 1 -name "${PREFIX}*.tar.gz" -print0)

    if [[ ${#archives[@]} -gt 0 ]]; then
        log_info "Найдены архивы для восстановления:"
        for i in "${!archives[@]}"; do
            echo "  $((i+1)). ${archives[i]}"
        done

        read -p "Хотите распаковать один из архивов? (y/N): " choice
        if [[ "$choice" =~ [yY] ]]; then
            read -p "Введите номер архива (1-${#archives[@]}): " archive_num
            if [[ "$archive_num" =~ ^[0-9]+$ ]] && [[ "$archive_num" -ge 1 ]] && [[ "$archive_num" -le ${#archives[@]} ]]; then
                restore_archive "${archives[$((archive_num-1))]}"
            else
                log_error "Неверный номер архива"
            fi
        fi
    fi
}

# Функция для восстановления архива
restore_archive() {
    local archive_path=$1

    if [[ ! -f "$archive_path" ]]; then
        log_error "Архив $archive_path не найден"
        return 1
    fi

    log_info "Восстановление из архива: $archive_path"

    # Создаем директорию восстановления
    if [[ -d "$RESTORE_DIR" ]]; then
        read -p "Директория $RESTORE_DIR уже существует. Перезаписать? (y/N): " choice
        if [[ ! "$choice" =~ [yY] ]]; then
            log_info "Восстановление отменено"
            return 0
        fi
        rm -rf "$RESTORE_DIR"
    fi

    mkdir -p "$RESTORE_DIR"

    # Распаковываем архив
    log_info "Распаковка архива..."
    if ! tar -xzf "$archive_path" -C "$RESTORE_DIR"; then
        log_error "Ошибка при распаковке архива"
        return 1
    fi

    log_success "Архив распакован в директорию: $RESTORE_DIR"
    log_info "Для запуска проекта выполните:"
    echo "  cd $RESTORE_DIR"
    echo "  ./restore.sh"
    echo ""
    echo "Или просмотрите README.md для получения инструкций"
}

# Основная функция
main() {
    check_commands

    log_info "Скрипт сохранения/восстановления Docker окружения"
    echo ""

    # Предлагаем восстановление если есть архивы
    find_and_offer_restore

    echo ""
    log_info "Режим работы:"
    echo "  1. Сохранить текущее окружение в архив"
    echo "  2. Восстановить из конкретного архива"
    echo "  3. Выйти"

    read -p "Выберите действие (1-3): " action

    case $action in
        1)
            local compose_file
            compose_file=$(find_docker_compose)
            save_images "$compose_file" "."
            ;;
        2)
            read -p "Введите путь к архиву: " archive_path
            restore_archive "$archive_path"
            ;;
        3)
            log_info "Выход"
            exit 0
            ;;
        *)
            log_error "Неверный выбор"
            exit 1
            ;;
    esac
}

# Запуск основной функции
main "$@"
