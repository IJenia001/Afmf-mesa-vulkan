#!/bin/bash
# AI FrameGen Installer for Mesa (OpenSUSE Leap/Tumbleweed)
# Требует прав root (sudo)

set -e

# --- Конфигурация ---
# Задайте версию Mesa. Если тег "mesa-25.0" отсутствует, измените значение переменной.
MESA_VERSION="24.3.4"
WORK_DIR="$HOME/mesa_ai_build"
MODEL_PATH="/usr/share/ai_models/framegen_model_2050.dat"

# --- Установка системных зависимостей ---
echo "Установка системных зависимостей..."
sudo zypper ref
sudo zypper -n install git gcc-c++ meson ninja libdrm-devel \
    llvm-devel vulkan-tools libX11-devel \
    libXext-devel libxcb-devel libxshmfence-devel libelf-devel \
    wayland-protocols-devel opencl-headers python3-pip

# --- Скачивание исходников Mesa ---
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [ ! -d mesa ]; then
    git clone https://gitlab.freedesktop.org/mesa/mesa.git
fi

# --- Переход на нужную версию ---
cd mesa
if ! git checkout "mesa-$MESA_VERSION"; then
    if ! git checkout "$MESA_VERSION"; then
        echo "Не удалось найти ветку или тег для версии $MESA_VERSION"
        exit 1
    fi
fi

# --- Патч для meson_options.txt ---
# Добавляем "ai" в список допустимых значений опции gallium-drivers
MESON_OPTIONS_FILE="meson_options.txt"
if [ -f "$MESON_OPTIONS_FILE" ]; then
    echo "Патчим $MESON_OPTIONS_FILE для добавления 'ai' в gallium-drivers..."
    if ! grep -q "'ai'" "$MESON_OPTIONS_FILE"; then
        # Вставляем 'ai' перед 'all'
        sed -i "s/'all'/'ai', 'all'/g" "$MESON_OPTIONS_FILE"
    else
        echo "'ai' уже присутствует в $MESON_OPTIONS_FILE"
    fi
else
    echo "Файл $MESON_OPTIONS_FILE не найден. Пропускаем патч."
fi

# --- Применение модификаций AI FrameGen ---
echo "Применение патчей AI Frame Generation..."

# Создание директории для драйвера
mkdir -p src/gallium/drivers/ai_framegen

# Создание файла драйвера: src/gallium/drivers/ai_framegen/ai_framegen.c
cat > src/gallium/drivers/ai_framegen/ai_framegen.c << 'EOL'
// File: src/gallium/drivers/ai_framegen/ai_framegen.c
#include "util/u_inlines.h"
#include "pipe/p_context.h"
#include "pipe/p_state.h"
#include "util/u_thread.h"
#include "ai_framegen.h"

enum ai_error {
    AI_SUCCESS = 0,
    AI_MEMORY_ERROR,
    AI_MODEL_LOAD_ERROR
};

struct frame_data {
    struct ai_model *model;
    struct frame *prev_frame;
    struct frame *cur_frame;
    pipe_mutex mutex;
    bool model_ready;
    struct frame frames[2];
    uint32_t current_idx;
    struct ai_config config;
};

/**
 * @brief Генерирует промежуточный кадр с использованием ИИ
 * @param ctx Контекст графического конвейера
 * @param data Данные для генерации кадров
 * @note Требует предварительной инициализации модели
 */
static void ai_generate_frame(struct pipe_context *ctx, struct frame_data *data) {
    pipe_mutex_lock(data->mutex);

    if (!data->model_ready) {
        pipe_mutex_unlock(data->mutex);
        return;
    }

    // Переключение буферов
    uint32_t idx = data->current_idx ^ 1;

    // Генерация нового кадра
    struct frame *new_frame = ai_model_infer(data->model,
        data->frames[data->current_idx],
        data->frames[idx]);

    // Обновление состояния
    pipe_set_frame(ctx, new_frame);
    data->current_idx = idx;

    pipe_mutex_unlock(data->mutex);
}

void ai_framegen_create_ex(struct pipe_context *ctx,
                         const char* model_path,
                         struct ai_config *cfg) {
    struct frame_data *data = calloc(1, sizeof(struct frame_data));
    if (!data) {
        fprintf(stderr, "AI FrameGen: Memory allocation failed\n");
        return;
    }

    data->mutex = pipe_mutex_init();
    data->config = *cfg;

    // Асинхронная загрузка модели
    data->model = ai_load_model(model_path);
    if (!data->model) {
        free(data);
        fprintf(stderr, "AI FrameGen: Model loading failed\n");
        return;
    }

    ctx->generate_frame = ai_generate_frame;
    ctx->priv_data = data;
    data->model_ready = true;
}

void ai_framegen_destroy(struct pipe_context *ctx) {
    struct frame_data *data = ctx->priv_data;
    if (data) {
        ai_free_model(data->model);
        pipe_mutex_destroy(data->mutex);
        free(data);
    }
}

// Добавляем драйвер в систему сборки Mesa
struct pipe_loader_driver ai_frame_loader = {
    .create_screen = ai_framegen_create_ex,
    .destroy = ai_framegen_destroy
};
EOL

# Создание заголовочного файла: src/gallium/drivers/ai_framegen/ai_framegen.h
cat > src/gallium/drivers/ai_framegen/ai_framegen.h << 'EOL'
#ifndef AI_FRAMEGEN_H
#define AI_FRAMEGEN_H

struct ai_config {
    enum color_space cs;
    enum resolution res;
    enum frame_rate fps;
};

struct ai_model;
struct frame;

void ai_framegen_create_ex(struct pipe_context *ctx,
                         const char* model_path,
                         struct ai_config *cfg);
void ai_framegen_destroy(struct pipe_context *ctx);

#endif
EOL

# Добавление драйвера в систему сборки Mesa: обновление meson.build
echo "gallium_drivers += 'ai'" >> src/gallium/drivers/meson.build

# --- Конфигурация и сборка ---
echo "Конфигурация сборки..."
meson setup builddir/ \
    -Dprefix=/usr \
    -Ddri-drivers= \
    -Dgallium-drivers=ai \
    -Dvulkan-drivers= \
    -Dglx=disabled \
    -Dgallium-nine=false \
    -Dshared-glapi=enabled \
    -Dgles2=enabled \
    -Dgbm=enabled \
    -Dplatforms=x11,wayland

echo "Компиляция..."
ninja -C builddir/

# --- Установка драйвера ---
echo "Установка модифицированного драйвера..."
sudo ninja -C builddir/ install

# --- Постустановочные шаги ---
echo "Обновление кеша библиотек..."
sudo ldconfig

echo "Обновление initramfs..."
sudo dracut -f

echo "Активация драйвера..."
sudo modprobe ai_framegen

echo "Установка завершена! Для применения изменений перезагрузите систему."
