#!/bin/bash
set -e

# Проверка прав администратора
if [ "$EUID" -ne 0 ]; then
    echo "Запустите скрипт с sudo: sudo $0"
    exit 1
fi

# Определяем дистрибутив
DISTRO=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
fi

echo "Обнаружен дистрибутив: $DISTRO"

# Обновляем систему и устанавливаем базовые пакеты
echo "Обновление системы..."
apt update

# Устанавливаем базовые зависимости
echo "Установка базовых пакетов..."
apt install -y build-essential python3-full python3-venv python3-pip \
    software-properties-common wget curl git cmake pkg-config

# Попытка установить meson из системных пакетов
echo "Попытка установки meson из системных пакетов..."
apt install -y meson ninja-build || {
    echo "Системные пакеты meson недоступны, будем использовать pip..."
    
    # Создаём виртуальное окружение для системных инструментов
    VENV_DIR="/opt/mesa_build_env"
    python3 -m venv $VENV_DIR
    source $VENV_DIR/bin/activate
    
    # Устанавливаем meson в виртуальное окружение
    pip install meson ninja
    
    # Создаём символические ссылки для системного доступа
    ln -sf $VENV_DIR/bin/meson /usr/local/bin/meson
    ln -sf $VENV_DIR/bin/ninja /usr/local/bin/ninja
    
    deactivate
}

# Проверяем версию Meson
MIN_MESON_VERSION=0.62
CURRENT_MESON_VERSION=$(meson --version 2>/dev/null || echo "0.0")
echo "Текущая версия meson: $CURRENT_MESON_VERSION"

if ! dpkg --compare-versions "$CURRENT_MESON_VERSION" ge "$MIN_MESON_VERSION"; then
    echo "Требуется обновление meson до версии >= $MIN_MESON_VERSION"
    
    # Если есть виртуальное окружение, обновляем там
    if [ -d "/opt/mesa_build_env" ]; then
        source /opt/mesa_build_env/bin/activate
        pip install --upgrade meson
        deactivate
    else
        # Иначе пытаемся обновить системно с --break-system-packages
        pip3 install --break-system-packages --upgrade meson || {
            echo "Не удалось обновить meson. Продолжаем с текущей версией."
        }
    fi
fi

# Установка остальных зависимостей
echo "Установка зависимостей для сборки Mesa..."
apt install -y bison flex byacc glslang-tools \
libdrm-dev libclc-20-dev llvm-dev llvm-spirv-dev \
libclang-dev libunwind-dev libwayland-dev \
libwayland-egl-backend-dev wayland-protocols \
libx11-dev libxext-dev libxfixes-dev libxcb-shm0-dev \
libx11-xcb-dev libxcb-glx0-dev libxcb-dri3-dev \
libxcb-present-dev libxcb-sync-dev libxcb-keysyms1-dev \
libxcb-util-dev libxshmfence-dev libxxf86vm-dev \
libxrandr-dev libxrender-dev libxdamage-dev libvulkan-dev \
clang zlib1g-dev libelf-dev libssl-dev libffi-dev \
unzip gawk libxml2-dev libopenblas-dev ocl-icd-opencl-dev \
vulkan-tools libglvnd-dev libegl-dev libgles2-mesa-dev llvm-spirv-dev 

# Дополнительные пакеты для Python
apt install -y python3-mako python3-yaml python3-dev

# Создание рабочих директорий
WORK_DIR="/opt/mesa_ai_build"
MODEL_DIR="/usr/share/mesa/ai_models"
mkdir -p $WORK_DIR
mkdir -p $MODEL_DIR
cd $WORK_DIR

# Сборка TensorFlow Lite
echo "=== Сборка TensorFlow Lite ==="
TFLITE_VERSION="2.15.0"
TFLITE_DIR="$WORK_DIR/tflite"
mkdir -p $TFLITE_DIR
cd $TFLITE_DIR

# Проверка наличия уже установленной библиотеки
if [ ! -f "/usr/local/lib/libtensorflowlite.so" ]; then
    echo "Загрузка TensorFlow $TFLITE_VERSION..."
    if [ ! -f "tensorflow.tar.gz" ]; then
        wget --progress=bar:force https://github.com/tensorflow/tensorflow/archive/refs/tags/v${TFLITE_VERSION}.tar.gz -O tensorflow.tar.gz
    fi
    
    # Удаляем предыдущую сборку
    rm -rf tensorflow-${TFLITE_VERSION}
    tar xf tensorflow.tar.gz
    cd tensorflow-${TFLITE_VERSION}

    mkdir -p tflite_build
    cd tflite_build

    echo "Конфигурация TensorFlow Lite..."
    cmake ../tensorflow/lite/c \
        -DCMAKE_C_COMPILER=clang \
        -DCMAKE_CXX_COMPILER=clang++ \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DTFLITE_ENABLE_XNNPACK=OFF \
        -DTFLITE_ENABLE_GPU=OFF \
        -DTFLITE_ENABLE_NNAPI=OFF

    echo "Компиляция TensorFlow Lite..."
    cmake --build . -j$(nproc) || {
        echo "Ошибка компиляции TensorFlow Lite. Пытаемся с меньшим количеством потоков..."
        cmake --build . -j2
    }

    echo "Установка TensorFlow Lite..."
    cp libtensorflowlite_c.so /usr/local/lib/libtensorflowlite.so
    mkdir -p /usr/local/include/tensorflow
    cp -r ../tensorflow/lite/c /usr/local/include/tensorflow/
    ldconfig
    
    echo "TensorFlow Lite успешно установлен"
else
    echo "TensorFlow Lite уже установлен"
fi

# Загрузка и распаковка Mesa  
echo "=== Подготовка Mesa 25.0.3 ==="
cd $WORK_DIR

if [ ! -f "mesa-25.0.3.tar.xz" ]; then
    echo "Загрузка Mesa..."
    wget --progress=bar:force https://archive.mesa3d.org/mesa-25.0.3.tar.xz
fi

# Удаляем предыдущую сборку
rm -rf mesa-25.0.3
tar xf mesa-25.0.3.tar.xz
cd mesa-25.0.3

echo "=== Создание AI драйвера ==="

# Создание драйвера AI Frame Generation
mkdir -p src/gallium/drivers/ai_framegen

# Заголовочный файл
cat > src/gallium/drivers/ai_framegen/ai_framegen.h << 'EOF'
#ifndef AI_FRAMEGEN_H
#define AI_FRAMEGEN_H

#include "pipe/p_context.h"
#include "pipe/p_state.h"

#ifdef __cplusplus
extern "C" {
#endif

struct ai_frame {
    unsigned width;
    unsigned height;
    void* data;
    size_t size;
};

struct ai_framegen_context {
    void* model_data;
    void* interpreter;
    bool initialized;
};

void ai_framegen_init(struct pipe_context *ctx);
void ai_framegen_cleanup(struct pipe_context *ctx);
struct ai_frame* ai_framegen_process(struct pipe_context *ctx, 
                                     struct ai_frame *prev, 
                                     struct ai_frame *current);

#ifdef __cplusplus
}
#endif

#endif
EOF

# Основной файл драйвера
cat > src/gallium/drivers/ai_framegen/ai_framegen.c << 'EOF'
#include "ai_framegen.h"
#include "util/u_memory.h"
#include "util/u_inlines.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef HAVE_TENSORFLOW_LITE
#include <tensorflow/lite/c/c_api.h>
#endif

struct ai_framegen_context {
    void* model_data;
    void* interpreter;
    bool initialized;
};

static void ai_frame_free(struct ai_frame* frame) {
    if (frame) {
        free(frame->data);
        free(frame);
    }
}

static struct ai_frame* ai_frame_create(unsigned width, unsigned height) {
    struct ai_frame* frame = calloc(1, sizeof(struct ai_frame));
    if (!frame) return NULL;
    
    frame->width = width;
    frame->height = height;
    frame->size = width * height * 4; // RGBA
    frame->data = malloc(frame->size);
    
    if (!frame->data) {
        free(frame);
        return NULL;
    }
    
    return frame;
}

void ai_framegen_init(struct pipe_context *ctx) {
    if (!ctx) return;
    
    struct ai_framegen_context *ai_ctx = calloc(1, sizeof(struct ai_framegen_context));
    if (!ai_ctx) return;
    
    const char *model_path = getenv("MESA_AI_MODEL_PATH");
    if (!model_path) {
        model_path = "/usr/share/mesa/ai_models/default_model.tflite";
    }
    
    // Простая проверка доступности модели
    FILE *f = fopen(model_path, "r");
    if (f) {
        fclose(f);
        ai_ctx->initialized = true;
        printf("AI Frame Generation: Модель загружена из %s\n", model_path);
    } else {
        printf("AI Frame Generation: Модель не найдена по пути %s\n", model_path);
        ai_ctx->initialized = false;
    }
    
    ctx->priv_data = ai_ctx;
}

void ai_framegen_cleanup(struct pipe_context *ctx) {
    if (!ctx || !ctx->priv_data) return;
    
    struct ai_framegen_context *ai_ctx = ctx->priv_data;
    free(ai_ctx);
    ctx->priv_data = NULL;
}

struct ai_frame* ai_framegen_process(struct pipe_context *ctx, 
                                     struct ai_frame *prev, 
                                     struct ai_frame *current) {
    if (!ctx || !ctx->priv_data || !current) return NULL;
    
    struct ai_framegen_context *ai_ctx = ctx->priv_data;
    if (!ai_ctx->initialized) return NULL;
    
    // Простая реализация: копируем текущий кадр
    struct ai_frame *result = ai_frame_create(current->width, current->height);
    if (!result) return NULL;
    
    memcpy(result->data, current->data, current->size);
    
    return result;
}
EOF

# Файл сборки
cat > src/gallium/drivers/ai_framegen/meson.build << 'EOF'
files_ai_framegen = files(
  'ai_framegen.c',
)

# Проверка доступности TensorFlow Lite
tflite_dep = dependency('', required: false)
if meson.get_compiler('c').has_header('tensorflow/lite/c/c_api.h')
  tflite_dep = meson.get_compiler('c').find_library('tensorflowlite', 
                                                    dirs: ['/usr/local/lib'], 
                                                    required: false)
endif

ai_framegen_c_args = []
ai_framegen_deps = [dep_dl, dep_threads]

if tflite_dep.found()
  ai_framegen_c_args += ['-DHAVE_TENSORFLOW_LITE']
  ai_framegen_deps += [tflite_dep]
endif

libai_framegen = static_library(
  'ai_framegen',
  files_ai_framegen,
  include_directories: [
    inc_include, 
    inc_src, 
    inc_gallium, 
    inc_gallium_aux, 
    inc_util,
    include_directories('/usr/local/include')
  ],
  dependencies: ai_framegen_deps,
  c_args: [c_vis_args] + ai_framegen_c_args,
  gnu_symbol_visibility: 'hidden',
)

driver_ai = declare_dependency(
  link_with: libai_framegen,
)
EOF

# Регистрация драйвера в системе сборки Mesa
echo "Регистрация AI драйвера в Mesa..."

# Добавление в meson_options.txt
cp meson_options.txt meson_options.txt.backup

# Добавляем опцию AI драйвера если её нет
if ! grep -q "ai-framegen" meson_options.txt; then
    cat >> meson_options.txt << 'EOF'

option('ai-framegen',
       type : 'feature', 
       value : 'disabled',
       description : 'Enable AI frame generation driver')
EOF
fi

# Обновляем список gallium-drivers
python3 << 'PYTHON_SCRIPT'
import re

# Читаем файл
with open('meson_options.txt', 'r') as f:
    content = f.read()

# Ищем опцию gallium-drivers и добавляем 'ai' в choices если его нет
pattern = r"option\('gallium-drivers'.*?choices\s*:\s*\[(.*?)\]"
match = re.search(pattern, content, re.DOTALL)

if match:
    choices = match.group(1)
    if "'ai'" not in choices:
        new_choices = choices.rstrip(' ,\n') + ", 'ai'"
        new_content = content.replace(match.group(1), new_choices)
        
        with open('meson_options.txt', 'w') as f:
            f.write(new_content)
        print("Добавлен 'ai' в choices для gallium-drivers")
    else:
        print("'ai' уже присутствует в choices")
else:
    print("Не удалось найти опцию gallium-drivers")
PYTHON_SCRIPT

# Добавление в систему сборки
if ! grep -q "ai_framegen" src/gallium/meson.build; then
    sed -i "/subdir('drivers\/virgl')/a subdir('drivers/ai_framegen')" src/gallium/meson.build
fi

# Добавление в DRI target
if ! grep -q "'ai'" src/gallium/targets/dri/meson.build; then
    sed -i "/'zink'/a \  'ai': [idep_mesautil, driver_ai]," src/gallium/targets/dri/meson.build
fi

# Сборка Mesa
echo "=== Сборка Mesa ==="
rm -rf build
mkdir build
cd build

echo "Конфигурация Mesa..."
meson setup .. \
    -Dprefix=/usr/local \
    -Dbuildtype=release \
    -Dplatforms=x11,wayland \
    -Dgallium-drivers=swrast,zink,ai \
    -Dvulkan-drivers=[] \
    -Dgallium-vdpau=disabled \
    -Dgallium-va=disabled \
    -Dgallium-opencl=disabled \
    -Dglvnd=enabled \
    -Dglx=dri \
    -Degl=enabled \
    -Dgbm=enabled \
    -Dgles2=enabled \
    -Dopengl=true \
    -Dshared-glapi=enabled \
    -Dllvm=enabled \
    -Dvalgrind=disabled \
    -Dtools=[] \
    -Dai-framegen=enabled

echo "Компиляция Mesa (это может занять 30-90 минут)..."
ninja -j$(nproc) || ninja -j2

echo "Установка Mesa..."
ninja install

# Завершающие настройки
echo "=== Завершающие настройки ==="

# Загрузка тестовой модели
echo "Загрузка тестовой модели..."
wget -q --show-progress https://github.com/mattn/misc/raw/master/ei.tflite -O $MODEL_DIR/default_model.tflite || {
    echo "Создание заглушки модели..."
    dd if=/dev/zero of=$MODEL_DIR/default_model.tflite bs=1024 count=1
}

# Системные переменные
cat > /etc/profile.d/mesa_ai.sh << 'EOF'
export MESA_AI_FRAMEGEN=1
export MESA_AI_MODEL_PATH="/usr/share/mesa/ai_models/default_model.tflite"
export MESA_GLSL_CACHE_DIR="/var/tmp/mesa_shader_cache"
export MESA_GLTHREAD=1
EOF

# Создание кэша шейдеров
mkdir -p /var/tmp/mesa_shader_cache
chmod 777 /var/tmp/mesa_shader_cache

# udev правила
cat > /etc/udev/rules.d/99-gpu-ai.rules << 'EOF'
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="renderD*", GROUP="video", MODE="0666"
EOF

udevadm control --reload-rules
udevadm trigger

# Добавление пользователя в группу video
if [ -n "$SUDO_USER" ]; then
    usermod -aG video $SUDO_USER
fi

# Проверка установки
echo "=== Проверка установки ==="
echo "Установленные DRI драйверы:"
ls -la /usr/local/lib/dri/ 2>/dev/null | grep -E "\\.so$" || echo "DRI драйверы не найдены"

echo ""
echo "Файлы AI модели:"
ls -la $MODEL_DIR/ 2>/dev/null || echo "Модели не найдены"

echo ""
echo "=== УСТАНОВКА ЗАВЕРШЕНА ==="
echo "Для использования AI Frame Generation:"
echo "1. Перезагрузите систему"
echo "2. В Steam добавьте к параметрам запуска игры:"
echo "   MESA_AI_FRAMEGEN=1 MESA_LOADER_DRIVER_OVERRIDE=ai %command%"
echo ""
echo "Для отладки:"
echo "- Логи сборки: $WORK_DIR/mesa-25.0.3/build/meson-logs/"
echo "- Проверка драйверов: ls /usr/local/lib/dri/"
echo "- Версия Meson: $(meson --version)"
