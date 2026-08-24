use polyglance_cabi::alignment::polyglance_alignment_pairs;
use polyglance_cabi::engine::{
    STREAM_EVENT_DELTA, STREAM_EVENT_DONE, polyglance_engine_free, polyglance_engine_new,
    polyglance_stream_event_parse, polyglance_translate,
};
use polyglance_cabi::geometry::{
    CPoint, CRect, POLYGLANCE_SELECTION_MOVE, POLYGLANCE_SELECTION_RESIZE_RIGHT,
    POLYGLANCE_SELECTION_RESIZE_TOP_LEFT, polyglance_selection_edit_target,
    polyglance_selection_edited, polyglance_selection_expanded_toward, polyglance_selection_rect,
};
use polyglance_cabi::layout::polyglance_layout_paragraphs;
use polyglance_cabi::recording::{
    CEncodingProfile, polyglance_recording_calculate_output, polyglance_recording_get_profile,
};
use polyglance_cabi::stitch::{
    CStitchAppendResult, CStitchConfiguration, polyglance_stitcher_append,
    polyglance_stitcher_free, polyglance_stitcher_get_dimensions, polyglance_stitcher_new,
    polyglance_stitcher_render, polyglance_stitcher_render_preview,
};
use polyglance_cabi::{
    POLYGLANCE_ERR_INVALID_CONFIG, POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_INVALID_RESPONSE,
    POLYGLANCE_ERR_PANIC, POLYGLANCE_OK, ffi_status, owned_bytes_into_raw, polyglance_free_buffer,
    polyglance_free_string,
};
use std::ffi::{CStr, CString};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::thread;

#[test]
fn test_owned_byte_buffer_round_trip_does_not_depend_on_vec_capacity() {
    unsafe {
        let mut bytes = Vec::with_capacity(4096);
        bytes.extend_from_slice(&[1, 2, 3, 4, 5]);
        assert!(bytes.capacity() > bytes.len());

        let (ptr, len) = owned_bytes_into_raw(bytes);
        assert!(!ptr.is_null());
        assert_eq!(len, 5);
        assert_eq!(std::slice::from_raw_parts(ptr, len), &[1, 2, 3, 4, 5]);

        polyglance_free_buffer(ptr, len);
    }
}

#[test]
fn test_ffi_status_converts_panics_into_error_codes() {
    let status = ffi_status(|| panic!("simulated ffi panic"));
    assert_eq!(status, POLYGLANCE_ERR_PANIC);
}

#[test]
fn test_selection_geometry_uses_windows_top_left_coordinate_names() {
    unsafe {
        let selection = CRect {
            x: 100.0,
            y: 80.0,
            width: 200.0,
            height: 120.0,
        };
        let mut target = 0;

        let status = polyglance_selection_edit_target(
            CPoint { x: 101.0, y: 81.0 },
            selection,
            6.0,
            &mut target,
        );

        assert_eq!(status, POLYGLANCE_OK);
        assert_eq!(target, POLYGLANCE_SELECTION_RESIZE_TOP_LEFT);
    }
}

#[test]
fn test_selection_geometry_normalizes_drag_rectangles_and_rejects_invalid_values() {
    unsafe {
        let bounds = CRect {
            x: 0.0,
            y: 0.0,
            width: 500.0,
            height: 400.0,
        };
        let mut output = CRect::default();

        assert_eq!(
            polyglance_selection_rect(
                CPoint { x: 300.0, y: 200.0 },
                CPoint { x: 100.0, y: 80.0 },
                bounds,
                &mut output,
            ),
            POLYGLANCE_OK
        );
        assert_eq!(
            output,
            CRect {
                x: 100.0,
                y: 80.0,
                width: 200.0,
                height: 120.0,
            }
        );

        assert_eq!(
            polyglance_selection_edited(
                output,
                CPoint { x: 0.0, y: 0.0 },
                CPoint { x: 1.0, y: 1.0 },
                999,
                bounds,
                4.0,
                &mut output,
            ),
            POLYGLANCE_ERR_INVALID_INPUT
        );
        assert_eq!(
            polyglance_selection_rect(
                CPoint {
                    x: f64::NAN,
                    y: 0.0
                },
                CPoint { x: 1.0, y: 1.0 },
                bounds,
                &mut output,
            ),
            POLYGLANCE_ERR_INVALID_INPUT
        );
    }
}

#[test]
fn test_selection_geometry_edits_and_expands_through_the_shared_core() {
    unsafe {
        let bounds = CRect {
            x: 0.0,
            y: 0.0,
            width: 500.0,
            height: 400.0,
        };
        let selection = CRect {
            x: 100.0,
            y: 80.0,
            width: 200.0,
            height: 120.0,
        };
        let mut output = CRect::default();

        assert_eq!(
            polyglance_selection_edited(
                selection,
                CPoint { x: 300.0, y: 140.0 },
                CPoint { x: 250.0, y: 140.0 },
                POLYGLANCE_SELECTION_RESIZE_RIGHT,
                bounds,
                4.0,
                &mut output,
            ),
            POLYGLANCE_OK
        );
        assert_eq!(
            output,
            CRect {
                x: 100.0,
                y: 80.0,
                width: 150.0,
                height: 120.0
            }
        );

        assert_eq!(
            polyglance_selection_edited(
                selection,
                CPoint { x: 150.0, y: 120.0 },
                CPoint { x: 175.0, y: 150.0 },
                POLYGLANCE_SELECTION_MOVE,
                bounds,
                4.0,
                &mut output,
            ),
            POLYGLANCE_OK
        );
        assert_eq!(
            output,
            CRect {
                x: 125.0,
                y: 110.0,
                width: 200.0,
                height: 120.0
            }
        );

        assert_eq!(
            polyglance_selection_expanded_toward(
                selection,
                CPoint { x: 350.0, y: 40.0 },
                bounds,
                &mut output,
            ),
            POLYGLANCE_OK
        );
        assert_eq!(
            output,
            CRect {
                x: 100.0,
                y: 40.0,
                width: 250.0,
                height: 160.0
            }
        );
    }
}

#[test]
fn test_engine_lifecycle() {
    unsafe {
        let mut engine = std::ptr::null_mut();
        let ret = polyglance_engine_new(&mut engine);
        assert_eq!(ret, POLYGLANCE_OK);
        assert!(!engine.is_null());
        polyglance_engine_free(engine);
    }
}

#[test]
fn test_translation_and_stream_parsing_cross_the_cabi_boundary() {
    unsafe {
        let (endpoint, server) = serve_once(r#"{"choices":[{"message":{"content":"你好"}}]}"#);
        let mut engine = std::ptr::null_mut();
        assert_eq!(polyglance_engine_new(&mut engine), POLYGLANCE_OK);

        let input = CString::new(format!(
            r#"{{"provider":"openai-compatible","endpoint":"{endpoint}","api_key":"test-key","model":"test-model","text":"Hello","source_language":"en","target_language":"zh-CN"}}"#
        ))
        .unwrap();
        let mut output = std::ptr::null_mut();
        assert_eq!(
            polyglance_translate(engine, input.as_ptr(), &mut output),
            POLYGLANCE_OK
        );
        assert!(CStr::from_ptr(output).to_str().unwrap().contains("你好"));
        polyglance_free_string(output);
        server.join().unwrap();

        let missing_key = CString::new(
            r#"{"provider":"openai-compatible","endpoint":"https://api.openai.com/v1","api_key":"","model":"test-model","text":"Hello","target_language":"zh-CN"}"#,
        )
        .unwrap();
        assert_eq!(
            polyglance_translate(engine, missing_key.as_ptr(), &mut output),
            POLYGLANCE_ERR_INVALID_CONFIG
        );
        let invalid_json = CString::new("{").unwrap();
        assert_eq!(
            polyglance_translate(engine, invalid_json.as_ptr(), &mut output),
            POLYGLANCE_ERR_INVALID_INPUT
        );

        let delta = CString::new(r#"data: {"choices":[{"delta":{"content":"片段"}}]}"#).unwrap();
        let mut event_type = 0;
        let mut text = std::ptr::null_mut();
        assert_eq!(
            polyglance_stream_event_parse(delta.as_ptr(), &mut event_type, &mut text),
            POLYGLANCE_OK
        );
        assert_eq!(event_type, STREAM_EVENT_DELTA);
        assert_eq!(CStr::from_ptr(text).to_str().unwrap(), "片段");
        polyglance_free_string(text);

        let done = CString::new("data: [DONE]").unwrap();
        assert_eq!(
            polyglance_stream_event_parse(done.as_ptr(), &mut event_type, &mut text),
            POLYGLANCE_OK
        );
        assert_eq!(event_type, STREAM_EVENT_DONE);
        assert!(text.is_null());

        let malformed = CString::new("data: {").unwrap();
        assert_eq!(
            polyglance_stream_event_parse(malformed.as_ptr(), &mut event_type, &mut text),
            POLYGLANCE_ERR_INVALID_RESPONSE
        );
        polyglance_engine_free(engine);
    }
}

#[test]
fn test_stitcher_lifecycle_and_append() {
    unsafe {
        let config = CStitchConfiguration {
            capture_interval: 0.05,
            maximum_frame_count: 50,
            maximum_output_width: 4000,
            maximum_output_height: 10000,
            maximum_pixel_count: 40_000_000,
            maximum_working_bytes: 200_000_000,
            minimum_overlap_rows: 10,
            maximum_scroll_fraction: 0.8,
            match_threshold: 0.9,
        };

        let mut stitcher = std::ptr::null_mut();
        let ret = polyglance_stitcher_new(&config, 0, &mut stitcher);
        assert_eq!(ret, POLYGLANCE_OK);
        assert!(!stitcher.is_null());

        let frame1 = vec![255u8; 100 * 100 * 4];
        let mut result = CStitchAppendResult {
            disposition: 0,
            offset: 0,
            frame_count: 0,
            total_width: 0,
            total_height: 0,
            limit_reached: 0,
        };

        let append_ret = polyglance_stitcher_append(
            stitcher,
            frame1.as_ptr(),
            frame1.len(),
            100,
            100,
            &mut result,
        );
        assert_eq!(append_ret, POLYGLANCE_OK);
        assert_eq!(result.frame_count, 1);
        assert_eq!(result.total_width, 100);
        assert_eq!(result.total_height, 100);

        let mut out_bytes = std::ptr::null_mut();
        let mut out_len = 0;
        let mut out_w = 0;
        let mut out_h = 0;
        let preview_ret = polyglance_stitcher_render_preview(
            stitcher,
            50,
            50,
            &mut out_bytes,
            &mut out_len,
            &mut out_w,
            &mut out_h,
        );
        assert_eq!(preview_ret, POLYGLANCE_OK);
        assert!(!out_bytes.is_null());
        assert!(out_len > 0);
        polyglance_free_buffer(out_bytes, out_len);

        let mut rendered_bytes = std::ptr::null_mut();
        let mut rendered_len = 0;
        assert_eq!(
            polyglance_stitcher_render(stitcher, &mut rendered_bytes, &mut rendered_len),
            POLYGLANCE_OK
        );
        assert_eq!(rendered_len, frame1.len());
        polyglance_free_buffer(rendered_bytes, rendered_len);

        let mut fc = 0;
        let mut w = 0;
        let mut h = 0;
        let mut off = 0;
        let dim_ret =
            polyglance_stitcher_get_dimensions(stitcher, &mut fc, &mut w, &mut h, &mut off);
        assert_eq!(dim_ret, POLYGLANCE_OK);
        assert_eq!(fc, 1);
        assert_eq!(w, 100);
        assert_eq!(h, 100);

        polyglance_stitcher_free(stitcher);
    }
}

fn serve_once(body: &'static str) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0_u8; 8192];
        let _ = stream.read(&mut request).unwrap();
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        stream.write_all(response.as_bytes()).unwrap();
    });
    (format!("http://{address}/v1"), server)
}

#[test]
fn test_layout_paragraphs_cabi() {
    unsafe {
        let lines_json = CString::new(
            r#"[
            {"text": "Hello", "x": 10.0, "y": 10.0, "width": 50.0, "height": 20.0},
            {"text": "World", "x": 65.0, "y": 10.0, "width": 50.0, "height": 20.0}
        ]"#,
        )
        .unwrap();

        let mut out_json = std::ptr::null_mut();
        let ret = polyglance_layout_paragraphs(lines_json.as_ptr(), &mut out_json);
        assert_eq!(ret, POLYGLANCE_OK);
        assert!(!out_json.is_null());

        let out_str = CStr::from_ptr(out_json).to_str().unwrap();
        assert!(out_str.contains("Hello"));
        polyglance_free_string(out_json);
    }
}

#[test]
fn test_alignment_pairs_cabi() {
    unsafe {
        let source = CString::new("Hello world. How are you?").unwrap();
        let target = CString::new("你好世界。你好吗？").unwrap();

        let mut out_json = std::ptr::null_mut();
        let ret = polyglance_alignment_pairs(source.as_ptr(), target.as_ptr(), &mut out_json);
        assert_eq!(ret, POLYGLANCE_OK);
        assert!(!out_json.is_null());

        let out_str = CStr::from_ptr(out_json).to_str().unwrap();
        assert!(out_str.contains("Hello world"));
        assert!(out_str.contains("你好世界"));
        polyglance_free_string(out_json);
    }
}

#[test]
fn test_recording_profiles_cabi() {
    unsafe {
        let mut profile = CEncodingProfile {
            frame_rate: 0,
            max_dimension: 0,
            bits_per_pixel_per_frame: 0.0,
            minimum_video_bitrate: 0,
            maximum_video_bitrate: 0,
            maximum_duration: 0.0,
            maximum_frame_count: 0,
        };

        let ret = polyglance_recording_get_profile(0, 1, &mut profile); // Mp4, Standard
        assert_eq!(ret, POLYGLANCE_OK);
        assert!(profile.frame_rate > 0);
        assert!(profile.max_dimension > 0);

        let mut out_w = 0.0;
        let mut out_h = 0.0;
        let mut bitrate = 0;
        let ret_calc = polyglance_recording_calculate_output(
            0,
            1,
            1920.0,
            1080.0,
            30,
            &mut out_w,
            &mut out_h,
            &mut bitrate,
        );
        assert_eq!(ret_calc, POLYGLANCE_OK);
        assert!(out_w > 0.0);
        assert!(out_h > 0.0);
        assert!(bitrate > 0);
    }
}
