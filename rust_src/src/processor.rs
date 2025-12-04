use crate::ffmpeg::*;
use std::ffi::CString;
use std::ptr;

pub struct ProcessorConfig {
    pub target_sample_rate: u32,
    pub min_duration_sec: f32,
    pub max_duration_sec: f32,
}

pub fn process_file(
    input_path: &str,
    output_path: &str,
    config: &ProcessorConfig,
) -> Result<(), String> {
    let input_cstr = CString::new(input_path).map_err(|e| e.to_string())?;
    let output_cstr = CString::new(output_path).map_err(|e| e.to_string())?;

    unsafe {
        let mut in_fmt_ctx: *mut AVFormatContext = ptr::null_mut();
        let ret = avformat_open_input(
            &mut in_fmt_ctx,
            input_cstr.as_ptr(),
            ptr::null(),
            ptr::null_mut(),
        );
        if ret < 0 || in_fmt_ctx.is_null() {
            return Err("Failed to open input".to_string());
        }

        let result = process_file_inner(in_fmt_ctx, &output_cstr, config);

        avformat_close_input(&mut in_fmt_ctx);
        result
    }
}

unsafe fn process_file_inner(
    in_fmt_ctx: *mut AVFormatContext,
    output_cstr: &CString,
    config: &ProcessorConfig,
) -> Result<(), String> {
    let wav_cstr = CString::new("wav").unwrap();
    let filter_size_cstr = CString::new("filter_size").unwrap();
    let cutoff_cstr = CString::new("cutoff").unwrap();

    let mut ret: i32;

    ret = avformat_find_stream_info(in_fmt_ctx, ptr::null_mut());
    if ret < 0 {
        return Err("Failed to find stream info".to_string());
    }

    let mut decoder: *const AVCodec = ptr::null();
    let stream_index = av_find_best_stream(
        in_fmt_ctx,
        AVMediaType_AVMEDIA_TYPE_AUDIO,
        -1,
        -1,
        &mut decoder,
        0,
    );
    if stream_index < 0 {
        return Err("No audio stream".to_string());
    }

    let in_stream = *(*in_fmt_ctx).streams.add(stream_index as usize);
    let codecpar = (*in_stream).codecpar;

    if decoder.is_null() {
        return Err("No decoder".to_string());
    }

    let dec_ctx = avcodec_alloc_context3(decoder);
    if dec_ctx.is_null() {
        return Err("Failed to alloc decoder context".to_string());
    }

    ret = avcodec_parameters_to_context(dec_ctx, codecpar);
    if ret < 0 {
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to copy params".to_string());
    }

    ret = avcodec_open2(dec_ctx, decoder, ptr::null_mut());
    if ret < 0 {
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to open decoder".to_string());
    }

    let in_sample_rate = (*dec_ctx).sample_rate;
    let in_ch_layout = (*dec_ctx).ch_layout;
    let channels = if in_ch_layout.nb_channels == 0 {
        2
    } else {
        in_ch_layout.nb_channels
    };
    let in_sample_fmt = (*dec_ctx).sample_fmt;

    // Output setup
    let mut out_fmt_ctx: *mut AVFormatContext = ptr::null_mut();
    ret = avformat_alloc_output_context2(
        &mut out_fmt_ctx,
        ptr::null(),
        wav_cstr.as_ptr(),
        output_cstr.as_ptr(),
    );
    if ret < 0 || out_fmt_ctx.is_null() {
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to alloc output".to_string());
    }

    let encoder = avcodec_find_encoder(AVCodecID_AV_CODEC_ID_PCM_F32LE);
    if encoder.is_null() {
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("No encoder".to_string());
    }

    let out_stream = avformat_new_stream(out_fmt_ctx, encoder);
    if out_stream.is_null() {
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to create stream".to_string());
    }

    let enc_ctx = avcodec_alloc_context3(encoder);
    if enc_ctx.is_null() {
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to alloc encoder context".to_string());
    }

    (*enc_ctx).sample_fmt = AVSampleFormat_AV_SAMPLE_FMT_FLT;
    (*enc_ctx).sample_rate = config.target_sample_rate as i32;
    av_channel_layout_default(&mut (*enc_ctx).ch_layout, channels);
    (*enc_ctx).bit_rate = (config.target_sample_rate * channels as u32 * 32) as i64;
    (*enc_ctx).time_base = AVRational {
        num: 1,
        den: config.target_sample_rate as i32,
    };

    if ((*(*out_fmt_ctx).oformat).flags & AVFMT_GLOBALHEADER as i32) != 0 {
        (*enc_ctx).flags |= AV_CODEC_FLAG_GLOBAL_HEADER as i32;
    }

    ret = avcodec_open2(enc_ctx, encoder, ptr::null_mut());
    if ret < 0 {
        avcodec_free_context(&mut (enc_ctx as *mut _));
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to open encoder".to_string());
    }

    ret = avcodec_parameters_from_context((*out_stream).codecpar, enc_ctx);
    if ret < 0 {
        avcodec_free_context(&mut (enc_ctx as *mut _));
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to copy encoder params".to_string());
    }

    (*out_stream).time_base = AVRational {
        num: 1,
        den: config.target_sample_rate as i32,
    };

    if ((*(*out_fmt_ctx).oformat).flags & AVFMT_NOFILE as i32) == 0 {
        ret = avio_open(
            &mut (*out_fmt_ctx).pb,
            output_cstr.as_ptr(),
            AVIO_FLAG_WRITE as i32,
        );
        if ret < 0 {
            avcodec_free_context(&mut (enc_ctx as *mut _));
            avformat_free_context(out_fmt_ctx);
            avcodec_free_context(&mut (dec_ctx as *mut _));
            return Err("Failed to open output file".to_string());
        }
    }

    ret = avformat_write_header(out_fmt_ctx, ptr::null_mut());
    if ret < 0 {
        avcodec_free_context(&mut (enc_ctx as *mut _));
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to write header".to_string());
    }

    // Resampler setup
    let mut swr_ctx: *mut SwrContext = ptr::null_mut();
    let mut dst_ch_layout = AVChannelLayout::default();
    av_channel_layout_default(&mut dst_ch_layout, channels);

    ret = swr_alloc_set_opts2(
        &mut swr_ctx,
        &mut dst_ch_layout as *mut _,
        AVSampleFormat_AV_SAMPLE_FMT_FLT,
        config.target_sample_rate as i32,
        &in_ch_layout as *const _ as *mut _,
        in_sample_fmt,
        in_sample_rate,
        0,
        ptr::null_mut(),
    );
    if ret < 0 || swr_ctx.is_null() {
        avcodec_free_context(&mut (enc_ctx as *mut _));
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to alloc resampler".to_string());
    }

    av_opt_set_int(swr_ctx as *mut _, filter_size_cstr.as_ptr(), 64, 0);
    av_opt_set_double(swr_ctx as *mut _, cutoff_cstr.as_ptr(), 0.97, 0);

    ret = swr_init(swr_ctx);
    if ret < 0 {
        swr_free(&mut swr_ctx);
        avcodec_free_context(&mut (enc_ctx as *mut _));
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to init resampler".to_string());
    }

    // Processing
    let dec_frame = av_frame_alloc();
    let enc_frame = av_frame_alloc();
    let pkt = av_packet_alloc();
    let out_pkt = av_packet_alloc();

    if dec_frame.is_null() || enc_frame.is_null() || pkt.is_null() || out_pkt.is_null() {
        av_frame_free(&mut (dec_frame as *mut _));
        av_frame_free(&mut (enc_frame as *mut _));
        av_packet_free(&mut (pkt as *mut _));
        av_packet_free(&mut (out_pkt as *mut _));
        swr_free(&mut swr_ctx);
        avcodec_free_context(&mut (enc_ctx as *mut _));
        avformat_free_context(out_fmt_ctx);
        avcodec_free_context(&mut (dec_ctx as *mut _));
        return Err("Failed to alloc frames/packets".to_string());
    }

    let max_samples = (config.max_duration_sec * config.target_sample_rate as f32) as usize;
    let min_samples = (config.min_duration_sec * config.target_sample_rate as f32) as usize;
    let mut total_output_samples: usize = 0;
    let mut pts: i64 = 0;

    let frame_size: usize = 1024;
    let mut resample_buf = vec![0f32; 8192];

    // Read and process packets
    while av_read_frame(in_fmt_ctx, pkt) >= 0 {
        if (*pkt).stream_index != stream_index {
            av_packet_unref(pkt);
            continue;
        }

        ret = avcodec_send_packet(dec_ctx, pkt);
        av_packet_unref(pkt);
        if ret < 0 {
            continue;
        }

        while avcodec_receive_frame(dec_ctx, dec_frame) >= 0 {
            if total_output_samples >= max_samples {
                av_frame_unref(dec_frame);
                break;
            }

            let in_nb_samples = (*dec_frame).nb_samples;
            let out_samples_est = av_rescale_rnd(
                in_nb_samples as i64,
                config.target_sample_rate as i64,
                in_sample_rate as i64,
                AVRounding_AV_ROUND_UP,
            ) as i32;

            let mut out_ptr = resample_buf.as_mut_ptr() as *mut u8;
            let in_ptr = (*dec_frame).extended_data;
            let max_out = (resample_buf.len() / channels as usize) as i32;

            let converted = swr_convert(
                swr_ctx,
                &mut out_ptr as *mut *mut u8,
                max_out.min(out_samples_est),
                in_ptr as *mut *const u8,
                in_nb_samples,
            );

            av_frame_unref(dec_frame);
            if converted <= 0 {
                continue;
            }

            let mut samples_to_write = converted as usize;
            let remaining = max_samples.saturating_sub(total_output_samples);
            if samples_to_write > remaining {
                samples_to_write = remaining;
            }

            let mut offset: usize = 0;
            while offset < samples_to_write {
                let chunk = frame_size.min(samples_to_write - offset);

                av_frame_unref(enc_frame);
                (*enc_frame).format = AVSampleFormat_AV_SAMPLE_FMT_FLT;
                (*enc_frame).sample_rate = config.target_sample_rate as i32;
                av_channel_layout_default(&mut (*enc_frame).ch_layout, channels);
                (*enc_frame).nb_samples = chunk as i32;

                ret = av_frame_get_buffer(enc_frame, 0);
                if ret < 0 {
                    break;
                }

                let src_start = offset * channels as usize;
                let bytes = chunk * channels as usize * 4;
                let dst = (*enc_frame).extended_data;
                std::ptr::copy_nonoverlapping(
                    resample_buf.as_ptr().add(src_start) as *const u8,
                    *dst,
                    bytes,
                );

                (*enc_frame).pts = pts;
                pts += chunk as i64;

                ret = avcodec_send_frame(enc_ctx, enc_frame);
                if ret < 0 {
                    continue;
                }

                while avcodec_receive_packet(enc_ctx, out_pkt) >= 0 {
                    av_packet_rescale_ts(out_pkt, (*enc_ctx).time_base, (*out_stream).time_base);
                    (*out_pkt).stream_index = (*out_stream).index;
                    av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                    av_packet_unref(out_pkt);
                }

                offset += chunk;
            }

            total_output_samples += samples_to_write;
            if total_output_samples >= max_samples {
                break;
            }
        }

        if total_output_samples >= max_samples {
            break;
        }
    }

    // Flush resampler
    while total_output_samples < max_samples {
        let mut out_ptr = resample_buf.as_mut_ptr() as *mut u8;
        let max_out = (resample_buf.len() / channels as usize) as i32;
        let flushed = swr_convert(swr_ctx, &mut out_ptr as *mut *mut u8, max_out, ptr::null_mut(), 0);
        if flushed <= 0 {
            break;
        }

        let mut samples_to_write = flushed as usize;
        let remaining = max_samples.saturating_sub(total_output_samples);
        if samples_to_write > remaining {
            samples_to_write = remaining;
        }

        let mut offset: usize = 0;
        while offset < samples_to_write {
            let chunk = frame_size.min(samples_to_write - offset);

            av_frame_unref(enc_frame);
            (*enc_frame).format = AVSampleFormat_AV_SAMPLE_FMT_FLT;
            (*enc_frame).sample_rate = config.target_sample_rate as i32;
            av_channel_layout_default(&mut (*enc_frame).ch_layout, channels);
            (*enc_frame).nb_samples = chunk as i32;

            ret = av_frame_get_buffer(enc_frame, 0);
            if ret < 0 {
                break;
            }

            let src_start = offset * channels as usize;
            let bytes = chunk * channels as usize * 4;
            let dst = (*enc_frame).extended_data;
            std::ptr::copy_nonoverlapping(
                resample_buf.as_ptr().add(src_start) as *const u8,
                *dst,
                bytes,
            );

            (*enc_frame).pts = pts;
            pts += chunk as i64;

            avcodec_send_frame(enc_ctx, enc_frame);
            while avcodec_receive_packet(enc_ctx, out_pkt) >= 0 {
                av_packet_rescale_ts(out_pkt, (*enc_ctx).time_base, (*out_stream).time_base);
                (*out_pkt).stream_index = (*out_stream).index;
                av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                av_packet_unref(out_pkt);
            }

            offset += chunk;
        }

        total_output_samples += samples_to_write;
    }

    // Pad with silence if needed
    if total_output_samples < min_samples {
        resample_buf.fill(0.0);
        let mut silence_remaining = min_samples - total_output_samples;

        while silence_remaining > 0 {
            let chunk = frame_size.min(silence_remaining);

            av_frame_unref(enc_frame);
            (*enc_frame).format = AVSampleFormat_AV_SAMPLE_FMT_FLT;
            (*enc_frame).sample_rate = config.target_sample_rate as i32;
            av_channel_layout_default(&mut (*enc_frame).ch_layout, channels);
            (*enc_frame).nb_samples = chunk as i32;

            ret = av_frame_get_buffer(enc_frame, 0);
            if ret < 0 {
                break;
            }

            let bytes = chunk * channels as usize * 4;
            let dst = (*enc_frame).extended_data;
            std::ptr::write_bytes(*dst, 0, bytes);

            (*enc_frame).pts = pts;
            pts += chunk as i64;

            avcodec_send_frame(enc_ctx, enc_frame);
            while avcodec_receive_packet(enc_ctx, out_pkt) >= 0 {
                av_packet_rescale_ts(out_pkt, (*enc_ctx).time_base, (*out_stream).time_base);
                (*out_pkt).stream_index = (*out_stream).index;
                av_interleaved_write_frame(out_fmt_ctx, out_pkt);
                av_packet_unref(out_pkt);
            }

            silence_remaining -= chunk;
        }
    }

    // Flush encoder
    avcodec_send_frame(enc_ctx, ptr::null());
    while avcodec_receive_packet(enc_ctx, out_pkt) >= 0 {
        av_packet_rescale_ts(out_pkt, (*enc_ctx).time_base, (*out_stream).time_base);
        (*out_pkt).stream_index = (*out_stream).index;
        av_interleaved_write_frame(out_fmt_ctx, out_pkt);
        av_packet_unref(out_pkt);
    }

    av_write_trailer(out_fmt_ctx);

    // Cleanup
    av_frame_free(&mut (dec_frame as *mut _));
    av_frame_free(&mut (enc_frame as *mut _));
    av_packet_free(&mut (pkt as *mut _));
    av_packet_free(&mut (out_pkt as *mut _));
    swr_free(&mut swr_ctx);
    avcodec_free_context(&mut (enc_ctx as *mut _));

    if ((*(*out_fmt_ctx).oformat).flags & AVFMT_NOFILE as i32) == 0 {
        avio_closep(&mut (*out_fmt_ctx).pb);
    }
    avformat_free_context(out_fmt_ctx);
    avcodec_free_context(&mut (dec_ctx as *mut _));

    Ok(())
}
