#!/bin/bash
set -e

# Проверка прав администратора
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт с sudo: sudo $0"
    exit 1
fi

# Проверяем версию Meson
MIN_MESON_VERSION=0.62
if ! dpkg --compare-versions $(meson --version) ge $MIN_MESON_VERSION; then
    echo "Обновление Meson..."
    pip3 install --upgrade meson
fi

# Установка зависимостей
apt update
apt install -y build-essential git meson ninja-build cmake pkg-config \
    libx11-dev libxext-dev libxfixes-dev libxcb-present-dev libxcb-dri3-dev \
    libxcb-randr0-dev libxcb-sync-dev libxshmfence-dev libxxf86vm-dev \
    libxrandr-dev libvulkan-dev libwayland-dev wayland-protocols \
    libdrm-dev zlib1g-dev libelf-dev libssl-dev libclang-dev \
    python3-pip python3-mako libffi-dev libxml2-dev \
    libopenblas-dev ocl-icd-opencl-dev clang \
    vulkan-tools wget curl unzip

# Создание рабочих директорий
WORK_DIR="/opt/mesa_ai_build"
MODEL_DIR="/usr/share/mesa/ai_models"
mkdir -p $WORK_DIR
mkdir -p $MODEL_DIR
cd $WORK_DIR

# Сборка TensorFlow Lite через CMake
echo "Сборка TensorFlow Lite..."
TFLITE_VERSION="2.15.0"
TFLITE_DIR="/opt/tflite"
mkdir -p $TFLITE_DIR
cd $TFLITE_DIR

# Удаляем предыдущую сборку, если существует
if [ -d "tensorflow-${TFLITE_VERSION}" ]; then
    echo "Удаление предыдущей сборки TensorFlow..."
    rm -rf "tensorflow-${TFLITE_VERSION}"
fi

wget -q https://github.com/tensorflow/tensorflow/archive/refs/tags/v${TFLITE_VERSION}.tar.gz -O tensorflow.tar.gz
tar xf tensorflow.tar.gz
cd tensorflow-${TFLITE_VERSION}

# Удаляем предыдущую сборку tflite
if [ -d "tflite_build" ]; then
    echo "Удаление предыдущей сборки tflite..."
    rm -rf tflite_build
fi

mkdir tflite_build
cd tflite_build

cmake ../tensorflow/lite/c \
    -DCMAKE_C_COMPILER=clang \
    -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=ON \
    -DTFLITE_ENABLE_XNNPACK=OFF \
    -DTFLITE_ENABLE_GPU=OFF \
    -DTFLITE_ENABLE_NNAPI=OFF

echo "Компиляция TensorFlow Lite (это займет 15-30 минут)..."
cmake --build . -j$(nproc)

echo "Установка TensorFlow Lite..."
cp libtensorflowlite_c.so /usr/local/lib/libtensorflowlite.so
cp -r ../tensorflow/lite/c /usr/local/include/tensorflow/
ldconfig

# Скачивание и распаковка Mesa
echo "Скачивание Mesa 25.0.3..."
cd $WORK_DIR

# Удаляем предыдущую сборку Mesa, если существует
if [ -d "mesa-25.0.3" ]; then
    echo "Удаление предыдущей сборки Mesa..."
    rm -rf mesa-25.0.3
fi

wget -q https://archive.mesa3d.org//mesa-25.0.3.tar.xz
tar xf mesa-25.0.3.tar.xz
cd mesa-25.0.3

# Регистрация нового драйвера в системе сборки Mesa
echo "Регистрация AI Frame Generation драйвера в Mesa..."

# 1. Добавляем опцию для драйвера в meson_options.txt
if ! grep -q "option('ai-framegen'" meson_options.txt; then
    cat >> meson_options.txt << 'EOF'

option('ai-framegen',
        type : 'feature',
        value : 'disabled',
        description : 'Enable AI frame generation driver')
EOF
fi

# 2. Добавляем драйвер в список Gallium
sed -i "/option('gallium-drivers',/a \  'ai'," meson_options.txt

# 3. Добавляем зависимость для драйвера
sed -i "/'zink': _zink_deps,/a \  'ai': [idep_mesautil, driver_ai]," src/gallium/targets/dri/meson.build

# Создание файлов драйвера AI Frame Generation
echo "Создание AI Frame Generation драйвера..."

# Создание директории драйвера
mkdir -p src/gallium/drivers/ai_framegen

# Файл: src/gallium/drivers/ai_framegen/ai_framegen.c
cat > src/gallium/drivers/ai_framegen/ai_framegen.c << 'EOF'
#include "util/u_inlines.h"
#include "util/u_memory.h"
#include "pipe/p_context.h"
#include "pipe/p_state.h"
#include "ai_framegen.h"
#include <tensorflow/lite/c/c_api.h>

struct frame_data {
    TfLiteModel* model;
    TfLiteInterpreter* interpreter;
};

static void ai_free_frame(struct frame* frame) {
    if (frame) {
        FREE(frame->data);
        FREE(frame);
    }
}

static TfLiteModel* ai_load_model(const char* path) {
    return TfLiteModelCreateFromFile(path);
}

static void ai_free_model(TfLiteModel* model) {
    if (model) TfLiteModelDelete(model);
}

static struct frame* ai_model_infer(TfLiteModel* model, struct frame* prev, struct frame* curr) {
    // В реальной реализации здесь будет логика обработки кадров
    // Для примера просто копируем текущий кадр
    struct frame* new_frame = CALLOC_STRUCT(frame);
    if (!new_frame) return NULL;
    
    new_frame->width = curr->width;
    new_frame->height = curr->height;
    new_frame->data = malloc(curr->width * curr->height * 4);
    memcpy(new_frame->data, curr->data, curr->width * curr->height * 4);
    
    return new_frame;
}

static void ai_generate_frame(struct pipe_context *ctx, 
                              struct frame *prev_frame,
                              struct frame *cur_frame) {
    struct frame_data *data = ctx->priv_data;
    
    if (!data || !data->model || !prev_frame || !cur_frame) 
        return;

    struct frame *new_frame = ai_model_infer(data->model, prev_frame, cur_frame);
    if (!new_frame)
        return;

    struct ai_framegen *fg = ctx->ai_framegen;
    if (fg && fg->set_generated_frame) {
        fg->set_generated_frame(ctx, new_frame);
    }
    
    ai_free_frame(new_frame);
}

void ai_framegen_create(struct pipe_context *ctx) {
    struct frame_data *data = CALLOC_STRUCT(frame_data);
    if (!data)
        return;

    const char *model_path = getenv("MESA_AI_MODEL_PATH");
    if (!model_path) model_path = "/usr/share/mesa/ai_models/default_model.tflite";
    
    data->model = ai_load_model(model_path);
    if (!data->model) {
        fprintf(stderr, "Failed to load AI model: %s\n", model_path);
        FREE(data);
        return;
    }

    // Создаем интерпретатор
    TfLiteInterpreterOptions* options = TfLiteInterpreterOptionsCreate();
    TfLiteInterpreterOptionsSetNumThreads(options, 2);
    data->interpreter = TfLiteInterpreterCreate(data->model, options);
    TfLiteInterpreterOptionsDelete(options);
    
    if (!data->interpreter) {
        fprintf(stderr, "Failed to create TFLite interpreter\n");
        ai_free_model(data->model);
        FREE(data);
        return;
    }

    ctx->priv_data = data;
    
    struct ai_framegen *fg = ctx->ai_framegen;
    if (fg) {
        fg->generate_frame = ai_generate_frame;
    }
}

void ai_framegen_destroy(struct pipe_context *ctx) {
    struct frame_data *data = ctx->priv_data;
    if (!data) 
        return;

    if (data->interpreter) {
        TfLiteInterpreterDelete(data->interpreter);
    }
    if (data->model) {
        ai_free_model(data->model);
    }
    
    FREE(data);
    ctx->priv_data = NULL;
}
EOF

# Файл: src/gallium/drivers/ai_framegen/meson.build
cat > src/gallium/drivers/ai_framegen/meson.build << 'EOF'
files_libai_framegen = files(
  'ai_framegen.c',
)

tflite_inc = include_directories('/usr/local/include')
tflite_lib = meson.get_compiler('c').find_library('tensorflowlite', dirs: ['/usr/local/lib'])

libai_framegen = static_library(
  'ai_framegen',
  files_libai_framegen,
  include_directories: [
    inc_include, inc_src, inc_gallium, inc_gallium_aux, inc_util, tflite_inc
  ],
  dependencies: [dep_dl, dep_threads, idep_nir_headers],
  link_args: ['-ltensorflowlite'],
  c_args: [c_vis_args],
  gnu_symbol_visibility: 'hidden',
)

driver_ai = declare_dependency(
  link_with: libai_framegen,
  dependencies: [idep_nir],
)
EOF

# Файл: src/gallium/include/pipe/p_ai_framegen.h
mkdir -p src/gallium/include/pipe
cat > src/gallium/include/pipe/p_ai_framegen.h << 'EOF'
#ifndef P_AI_FRAMEGEN_H
#define P_AI_FRAMEGEN_H

#include "pipe/p_context.h"
#include "pipe/p_state.h"

#ifdef __cplusplus
extern "C" {
#endif

struct ai_model;
struct frame {
    unsigned width;
    unsigned height;
    void* data;
};

struct ai_framegen {
    void (*set_generated_frame)(struct pipe_context *ctx, struct frame *frame);
    void (*generate_frame)(struct pipe_context *ctx, struct frame *prev, struct frame *current);
};

void ai_framegen_init(struct pipe_context *ctx);
void ai_framegen_cleanup(struct pipe_context *ctx);

#ifdef __cplusplus
}
#endif

#endif
EOF

# Прямое редактирование файла сборки вместо применения патча
echo "Обновление файла сборки Gallium..."
sed -i "/subdir('drivers\/virgl')/a subdir('drivers/ai_framegen')" src/gallium/meson.build

# Проверяем, что изменение применилось
if ! grep -q "subdir('drivers/ai_framegen')" src/gallium/meson.build; then
    echo "Ошибка: Не удалось обновить src/gallium/meson.build"
    exit 1
fi

# Сборка Mesa
echo "Конфигурация сборки..."
mkdir build
cd build

meson setup .. \
    -Dprefix=/usr/local \
    -Dbuildtype=release \
    -Dplatforms=x11,wayland \
    -Dgallium-drivers=swrast,zink,ai \
    -Dvulkan-drivers=swrast \
    -Ddri-drivers=swrast \
    -Dgallium-extra-hud=true \
    -Dgallium-vdpau=enabled \
    -Dgallium-va=enabled \
    -Dgallium-opencl=disabled \
    -Dglvnd=true \
    -Dglx=disabled \
    -Degl=enabled \
    -Dgbm=enabled \
    -Dgles2=enabled \
    -Dopengl=true \
    -Dshared-glapi=true \
    -Dllvm=disabled \
    -Dvalgrind=disabled \
    -Dtools=[] \
    -Dai-framegen=enabled

echo "Компиляция (это займет 20-60 минут)..."
ninja

echo "Установка..."
ninja install

# Загрузка тестовой модели
echo "Загрузка тестовой модели..."
wget -q https://github.com/mattn/misc/raw/master/ei.tflite -O $MODEL_DIR/default_model.tflite

# Настройка среды
echo "Настройка системных переменных..."
cat > /etc/profile.d/mesa_ai.sh << 'EOC'
export MESA_AI_FRAMEGEN=1
export MESA_AI_MODEL_PATH="/usr/share/mesa/ai_models/default_model.tflite"
export MESA_GLSL_CACHE_DIR="/var/tmp/mesa_shader_cache"
export MESA_GLTHREAD=1
export TF_FORCE_GPU_ALLOW_GROWTH=true
EOC

source /etc/profile.d/mesa_ai.sh

mkdir -p /var/tmp/mesa_shader_cache
chmod 777 /var/tmp/mesa_shader_cache

# Настройка udev
echo "Настройка прав доступа GPU..."
cat > /etc/udev/rules.d/99-gpu-ai.rules << 'EOC'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="video", MODE="0666"
EOC

udevadm control --reload-rules
udevadm trigger

# Добавление пользователя в группу video
usermod -aG video $SUDO_USER

# Тест установки
echo "Проверка установки..."
if [ -f /usr/local/lib/dri/ai_framegen_dri.so ]; then
    echo "Успех: AI Frame Generation установлен!"
    echo "Путь к драйверу: /usr/local/lib/dri/ai_framegen_dri.so"
else
    echo "Ошибка: Драйвер не найден!"
    exit 1
fi

echo "Для применения настроек перезагрузите систему."
echo "Для использования в Steam добавьте в параметры запуска:"
echo "MESA_AI_FRAMEGEN=1 %command%"
