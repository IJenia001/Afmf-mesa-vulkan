// File: src/gallium/drivers/ai_framegen/ai_framegen.c
#include "util/u_inlines.h"
#include "util/u_memory.h"
#include "pipe/p_context.h"
#include "pipe/p_state.h"
#include "ai_framegen.h"

struct frame_data {
    struct ai_model *model;
};

static void ai_generate_frame(struct pipe_context *ctx, 
                              struct frame *prev_frame,
                              struct frame *cur_frame) {
    struct frame_data *data = ctx->priv_data;
    
    if (!data || !data->model || !prev_frame || !cur_frame) 
        return;

    struct frame *new_frame = ai_model_infer(data->model, prev_frame, cur_frame);
    if (!new_frame)
        return;

    // Интеграция в pipe_context через существующий механизм
    struct ai_framegen *fg = ctx->ai_framegen;
    if (fg && fg->set_generated_frame) {
        fg->set_generated_frame(ctx, new_frame);
    }
    
    ai_free_frame(new_frame);  // Освобождение кадра после использования
}

void ai_framegen_create(struct pipe_context *ctx) {
    struct frame_data *data = CALLOC_STRUCT(frame_data);
    if (!data)
        return;

    data->model = ai_load_model("framegen_model_2050.dat");
    if (!data->model) {
        FREE(data);
        return;
    }

    ctx->priv_data = data;
    
    // Регистрация callback в существующей системе
    struct ai_framegen *fg = ctx->ai_framegen;
    if (fg) {
        fg->generate_frame = ai_generate_frame;
    }
}

void ai_framegen_destroy(struct pipe_context *ctx) {
    struct frame_data *data = ctx->priv_data;
    if (!data) 
        return;

    if (data->model) {
        ai_free_model(data->model);
        data->model = NULL;
    }
    
    FREE(data);
    ctx->priv_data = NULL;
}
