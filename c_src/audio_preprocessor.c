#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <pthread.h>
#include <unistd.h>

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/opt.h>
#include <libavutil/channel_layout.h>
#include <libswresample/swresample.h>

typedef struct {
    uint32_t target_sample_rate;
    float min_duration_sec;
    float max_duration_sec;
} ProcessorConfig;

typedef struct {
    char *input_path;
    char *output_path;
    ProcessorConfig config;
} ProcessTask;

typedef struct {
    ProcessTask *tasks;
    int task_count;
    int next_task;
    pthread_mutex_t mutex;
} ThreadPool;

static int is_audio_file(const char *filename) {
    const char *extensions[] = {".mp3", ".wav", ".flac", ".m4a", ".ogg", ".aac", ".wma", ".opus", NULL};
    size_t len = strlen(filename);
    
    for (int i = 0; extensions[i]; i++) {
        size_t ext_len = strlen(extensions[i]);
        if (len > ext_len && strcasecmp(filename + len - ext_len, extensions[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static int process_file(const char *input_path, const char *output_path, ProcessorConfig *config) {
    AVFormatContext *in_fmt_ctx = NULL;
    AVFormatContext *out_fmt_ctx = NULL;
    AVCodecContext *dec_ctx = NULL;
    AVCodecContext *enc_ctx = NULL;
    SwrContext *swr_ctx = NULL;
    AVFrame *dec_frame = NULL;
    AVFrame *enc_frame = NULL;
    AVPacket *pkt = NULL;
    AVPacket *out_pkt = NULL;
    int ret = 0;
    int stream_index = -1;
    
    // Open input
    ret = avformat_open_input(&in_fmt_ctx, input_path, NULL, NULL);
    if (ret < 0) goto cleanup;
    
    ret = avformat_find_stream_info(in_fmt_ctx, NULL);
    if (ret < 0) goto cleanup;
    
    // Find audio stream
    stream_index = av_find_best_stream(in_fmt_ctx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (stream_index < 0) { ret = stream_index; goto cleanup; }
    
    AVStream *in_stream = in_fmt_ctx->streams[stream_index];
    const AVCodec *decoder = avcodec_find_decoder(in_stream->codecpar->codec_id);
    if (!decoder) { ret = -1; goto cleanup; }
    
    dec_ctx = avcodec_alloc_context3(decoder);
    if (!dec_ctx) { ret = -1; goto cleanup; }
    
    ret = avcodec_parameters_to_context(dec_ctx, in_stream->codecpar);
    if (ret < 0) goto cleanup;
    
    ret = avcodec_open2(dec_ctx, decoder, NULL);
    if (ret < 0) goto cleanup;
    
    int in_sample_rate = dec_ctx->sample_rate;
    int channels = dec_ctx->ch_layout.nb_channels;
    if (channels == 0) channels = 2;
    
    // Setup output
    ret = avformat_alloc_output_context2(&out_fmt_ctx, NULL, "wav", output_path);
    if (ret < 0 || !out_fmt_ctx) goto cleanup;
    
    const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_PCM_F32LE);
    if (!encoder) { ret = -1; goto cleanup; }
    
    AVStream *out_stream = avformat_new_stream(out_fmt_ctx, encoder);
    if (!out_stream) { ret = -1; goto cleanup; }
    
    enc_ctx = avcodec_alloc_context3(encoder);
    if (!enc_ctx) { ret = -1; goto cleanup; }
    
    enc_ctx->sample_fmt = AV_SAMPLE_FMT_FLT;
    enc_ctx->sample_rate = config->target_sample_rate;
    av_channel_layout_default(&enc_ctx->ch_layout, channels);
    enc_ctx->bit_rate = config->target_sample_rate * channels * 32;
    
    if (out_fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER)
        enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    
    ret = avcodec_open2(enc_ctx, encoder, NULL);
    if (ret < 0) goto cleanup;
    
    ret = avcodec_parameters_from_context(out_stream->codecpar, enc_ctx);
    if (ret < 0) goto cleanup;
    
    out_stream->time_base = (AVRational){1, config->target_sample_rate};
    
    if (!(out_fmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&out_fmt_ctx->pb, output_path, AVIO_FLAG_WRITE);
        if (ret < 0) goto cleanup;
    }
    
    ret = avformat_write_header(out_fmt_ctx, NULL);
    if (ret < 0) goto cleanup;
    
    // Setup resampler
    AVChannelLayout dst_ch_layout = {0};
    av_channel_layout_default(&dst_ch_layout, channels);
    
    ret = swr_alloc_set_opts2(&swr_ctx,
        &dst_ch_layout, AV_SAMPLE_FMT_FLT, config->target_sample_rate,
        &dec_ctx->ch_layout, dec_ctx->sample_fmt, dec_ctx->sample_rate,
        0, NULL);
    if (ret < 0 || !swr_ctx) goto cleanup;
    
    av_opt_set_int(swr_ctx, "filter_size", 64, 0);
    av_opt_set_double(swr_ctx, "cutoff", 0.97, 0);
    
    ret = swr_init(swr_ctx);
    if (ret < 0) goto cleanup;
    
    // Allocate frames and packets
    dec_frame = av_frame_alloc();
    enc_frame = av_frame_alloc();
    pkt = av_packet_alloc();
    out_pkt = av_packet_alloc();
    if (!dec_frame || !enc_frame || !pkt || !out_pkt) { ret = -1; goto cleanup; }
    
    size_t max_samples = (size_t)(config->max_duration_sec * config->target_sample_rate);
    size_t min_samples = (size_t)(config->min_duration_sec * config->target_sample_rate);
    size_t total_output_samples = 0;
    int64_t pts = 0;
    
    float resample_buf[8192];
    int frame_size = 1024;
    
    // Process packets
    while (av_read_frame(in_fmt_ctx, pkt) >= 0) {
        if (pkt->stream_index != stream_index) {
            av_packet_unref(pkt);
            continue;
        }
        
        ret = avcodec_send_packet(dec_ctx, pkt);
        av_packet_unref(pkt);
        if (ret < 0) continue;
        
        while (avcodec_receive_frame(dec_ctx, dec_frame) >= 0) {
            if (total_output_samples >= max_samples) {
                av_frame_unref(dec_frame);
                break;
            }
            
            int out_samples_est = av_rescale_rnd(dec_frame->nb_samples,
                config->target_sample_rate, in_sample_rate, AV_ROUND_UP);
            
            uint8_t *out_ptr = (uint8_t *)resample_buf;
            int max_out = sizeof(resample_buf) / sizeof(float) / channels;
            if (out_samples_est > max_out) out_samples_est = max_out;
            
            int converted = swr_convert(swr_ctx, &out_ptr, out_samples_est,
                (const uint8_t **)dec_frame->extended_data, dec_frame->nb_samples);
            
            av_frame_unref(dec_frame);
            if (converted <= 0) continue;
            
            size_t samples_to_write = converted;
            size_t remaining = max_samples - total_output_samples;
            if (samples_to_write > remaining) samples_to_write = remaining;
            
            size_t offset = 0;
            while (offset < samples_to_write) {
                size_t chunk = frame_size;
                if (chunk > samples_to_write - offset) chunk = samples_to_write - offset;
                
                av_frame_unref(enc_frame);
                enc_frame->format = AV_SAMPLE_FMT_FLT;
                enc_frame->sample_rate = config->target_sample_rate;
                av_channel_layout_default(&enc_frame->ch_layout, channels);
                enc_frame->nb_samples = chunk;
                
                ret = av_frame_get_buffer(enc_frame, 0);
                if (ret < 0) break;
                
                memcpy(enc_frame->extended_data[0], 
                       &resample_buf[offset * channels], 
                       chunk * channels * sizeof(float));
                
                enc_frame->pts = pts;
                pts += chunk;
                
                ret = avcodec_send_frame(enc_ctx, enc_frame);
                if (ret < 0) continue;
                
                while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                    av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
                    out_pkt->stream_index = out_stream->index;
                    av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                    av_packet_unref(out_pkt);
                }
                
                offset += chunk;
            }
            
            total_output_samples += samples_to_write;
            if (total_output_samples >= max_samples) break;
        }
        
        if (total_output_samples >= max_samples) break;
    }
    
    // Flush resampler
    while (total_output_samples < max_samples) {
        uint8_t *out_ptr = (uint8_t *)resample_buf;
        int max_out = sizeof(resample_buf) / sizeof(float) / channels;
        int flushed = swr_convert(swr_ctx, &out_ptr, max_out, NULL, 0);
        if (flushed <= 0) break;
        
        size_t samples_to_write = flushed;
        size_t remaining = max_samples - total_output_samples;
        if (samples_to_write > remaining) samples_to_write = remaining;
        
        size_t offset = 0;
        while (offset < samples_to_write) {
            size_t chunk = frame_size;
            if (chunk > samples_to_write - offset) chunk = samples_to_write - offset;
            
            av_frame_unref(enc_frame);
            enc_frame->format = AV_SAMPLE_FMT_FLT;
            enc_frame->sample_rate = config->target_sample_rate;
            av_channel_layout_default(&enc_frame->ch_layout, channels);
            enc_frame->nb_samples = chunk;
            
            ret = av_frame_get_buffer(enc_frame, 0);
            if (ret < 0) break;
            
            memcpy(enc_frame->extended_data[0],
                   &resample_buf[offset * channels],
                   chunk * channels * sizeof(float));
            
            enc_frame->pts = pts;
            pts += chunk;
            
            avcodec_send_frame(enc_ctx, enc_frame);
            while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
                out_pkt->stream_index = out_stream->index;
                av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                av_packet_unref(out_pkt);
            }
            
            offset += chunk;
        }
        
        total_output_samples += samples_to_write;
    }
    
    // Pad with silence if needed
    if (total_output_samples < min_samples) {
        memset(resample_buf, 0, sizeof(resample_buf));
        size_t silence_remaining = min_samples - total_output_samples;
        
        while (silence_remaining > 0) {
            size_t chunk = frame_size;
            if (chunk > silence_remaining) chunk = silence_remaining;
            
            av_frame_unref(enc_frame);
            enc_frame->format = AV_SAMPLE_FMT_FLT;
            enc_frame->sample_rate = config->target_sample_rate;
            av_channel_layout_default(&enc_frame->ch_layout, channels);
            enc_frame->nb_samples = chunk;
            
            ret = av_frame_get_buffer(enc_frame, 0);
            if (ret < 0) break;
            
            memset(enc_frame->extended_data[0], 0, chunk * channels * sizeof(float));
            
            enc_frame->pts = pts;
            pts += chunk;
            
            avcodec_send_frame(enc_ctx, enc_frame);
            while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
                av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
                out_pkt->stream_index = out_stream->index;
                av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                av_packet_unref(out_pkt);
            }
            
            silence_remaining -= chunk;
        }
    }
    
    // Flush encoder
    avcodec_send_frame(enc_ctx, NULL);
    while (avcodec_receive_packet(enc_ctx, out_pkt) >= 0) {
        av_packet_rescale_ts(out_pkt, enc_ctx->time_base, out_stream->time_base);
        out_pkt->stream_index = out_stream->index;
        av_interleaved_write_frame(out_fmt_ctx, out_pkt);
        av_packet_unref(out_pkt);
    }
    
    av_write_trailer(out_fmt_ctx);
    ret = 0;

cleanup:
    av_packet_free(&out_pkt);
    av_packet_free(&pkt);
    av_frame_free(&enc_frame);
    av_frame_free(&dec_frame);
    swr_free(&swr_ctx);
    if (enc_ctx) avcodec_free_context(&enc_ctx);
    if (dec_ctx) avcodec_free_context(&dec_ctx);
    if (out_fmt_ctx) {
        if (!(out_fmt_ctx->oformat->flags & AVFMT_NOFILE))
            avio_closep(&out_fmt_ctx->pb);
        avformat_free_context(out_fmt_ctx);
    }
    if (in_fmt_ctx) avformat_close_input(&in_fmt_ctx);
    
    return ret;
}

static void *worker_thread(void *arg) {
    ThreadPool *pool = (ThreadPool *)arg;
    
    while (1) {
        pthread_mutex_lock(&pool->mutex);
        int task_idx = pool->next_task++;
        pthread_mutex_unlock(&pool->mutex);
        
        if (task_idx >= pool->task_count) break;
        
        ProcessTask *task = &pool->tasks[task_idx];
        int ret = process_file(task->input_path, task->output_path, &task->config);
        
        if (ret == 0) {
            printf("Processed: %s\n", task->input_path);
        } else {
            fprintf(stderr, "Failed: %s\n", task->input_path);
        }
    }
    
    return NULL;
}

static int collect_files_recursive(const char *dir_path, const char *rel_path,
                                   const char *output_dir, ProcessorConfig *config,
                                   ProcessTask **tasks, int *count, int *capacity) {
    DIR *dir = opendir(dir_path);
    if (!dir) return -1;
    
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        
        char full_path[4096];
        snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, entry->d_name);
        
        char new_rel_path[4096];
        if (rel_path[0]) {
            snprintf(new_rel_path, sizeof(new_rel_path), "%s/%s", rel_path, entry->d_name);
        } else {
            snprintf(new_rel_path, sizeof(new_rel_path), "%s", entry->d_name);
        }
        
        struct stat st;
        if (stat(full_path, &st) != 0) continue;
        
        if (S_ISDIR(st.st_mode)) {
            collect_files_recursive(full_path, new_rel_path, output_dir, config, tasks, count, capacity);
        } else if (S_ISREG(st.st_mode) && is_audio_file(entry->d_name)) {
            if (*count >= *capacity) {
                *capacity = *capacity ? *capacity * 2 : 256;
                *tasks = realloc(*tasks, *capacity * sizeof(ProcessTask));
            }
            
            // Build output path
            char *dot = strrchr(entry->d_name, '.');
            size_t stem_len = dot ? (size_t)(dot - entry->d_name) : strlen(entry->d_name);
            
            char output_path[4096];
            if (rel_path[0]) {
                char *last_slash = strrchr(new_rel_path, '/');
                if (last_slash) {
                    *last_slash = '\0';
                    snprintf(output_path, sizeof(output_path), "%s/%s/%.*s.wav",
                             output_dir, new_rel_path, (int)stem_len, entry->d_name);
                    *last_slash = '/';
                } else {
                    snprintf(output_path, sizeof(output_path), "%s/%.*s.wav",
                             output_dir, (int)stem_len, entry->d_name);
                }
            } else {
                snprintf(output_path, sizeof(output_path), "%s/%.*s.wav",
                         output_dir, (int)stem_len, entry->d_name);
            }
            
            ProcessTask *task = &(*tasks)[*count];
            task->input_path = strdup(full_path);
            task->output_path = strdup(output_path);
            task->config = *config;
            (*count)++;
        }
    }
    
    closedir(dir);
    return 0;
}

static void ensure_dir(const char *path) {
    char tmp[4096];
    snprintf(tmp, sizeof(tmp), "%s", path);
    
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

int main(int argc, char **argv) {
    if (argc < 3) {
        printf("Usage: %s <input_dir> <output_dir> [options]\n\n", argv[0]);
        printf("Options:\n");
        printf("  --sample-rate <rate>   Target sample rate (default: 16000)\n");
        printf("  --min-duration <sec>   Minimum duration (default: 3.0)\n");
        printf("  --max-duration <sec>   Maximum duration (default: 5.0)\n");
        printf("  --threads <num>        Number of threads (default: auto)\n");
        return 1;
    }
    
    const char *input_dir = argv[1];
    const char *output_dir = argv[2];
    
    ProcessorConfig config = {
        .target_sample_rate = 16000,
        .min_duration_sec = 3.0f,
        .max_duration_sec = 5.0f
    };
    
    int num_threads = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (num_threads < 1) num_threads = 4;
    
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--sample-rate") == 0 && i + 1 < argc) {
            config.target_sample_rate = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--min-duration") == 0 && i + 1 < argc) {
            config.min_duration_sec = atof(argv[++i]);
        } else if (strcmp(argv[i], "--max-duration") == 0 && i + 1 < argc) {
            config.max_duration_sec = atof(argv[++i]);
        } else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc) {
            num_threads = atoi(argv[++i]);
        }
    }
    
    printf("Audio Dataset Preprocessor (C)\n");
    printf("Input:  %s\n", input_dir);
    printf("Output: %s\n", output_dir);
    printf("Target sample rate: %u Hz\n", config.target_sample_rate);
    printf("Duration range: %.1fs - %.1fs\n", config.min_duration_sec, config.max_duration_sec);
    
    // Collect files
    ProcessTask *tasks = NULL;
    int task_count = 0;
    int capacity = 0;
    
    collect_files_recursive(input_dir, "", output_dir, &config, &tasks, &task_count, &capacity);
    
    printf("Found %d audio files\n", task_count);
    
    if (task_count == 0) {
        printf("No audio files found.\n");
        return 0;
    }
    
    // Create output directories
    for (int i = 0; i < task_count; i++) {
        char *dir = strdup(tasks[i].output_path);
        char *last_slash = strrchr(dir, '/');
        if (last_slash) {
            *last_slash = '\0';
            ensure_dir(dir);
        }
        free(dir);
    }
    
    if (num_threads > task_count) num_threads = task_count;
    printf("Processing with %d threads...\n", num_threads);
    
    // Thread pool
    ThreadPool pool = {
        .tasks = tasks,
        .task_count = task_count,
        .next_task = 0
    };
    pthread_mutex_init(&pool.mutex, NULL);
    
    pthread_t *threads = malloc(num_threads * sizeof(pthread_t));
    for (int i = 0; i < num_threads; i++) {
        pthread_create(&threads[i], NULL, worker_thread, &pool);
    }
    
    for (int i = 0; i < num_threads; i++) {
        pthread_join(threads[i], NULL);
    }
    
    printf("Processing complete!\n");
    
    // Cleanup
    free(threads);
    pthread_mutex_destroy(&pool.mutex);
    for (int i = 0; i < task_count; i++) {
        free(tasks[i].input_path);
        free(tasks[i].output_path);
    }
    free(tasks);
    
    return 0;
}
