use serde::{Deserialize, Serialize};
use std::ffi::{c_char, c_void};
use std::sync::Arc;
use tokio::runtime::{Builder, Runtime};
use translator_core::{TranslationError as CoreError, TranslationRequest};
use translator_providers::dispatch;
use translator_providers::openai::ProviderError;
use translator_providers::streaming;

use crate::{
    POLYGLANCE_ERR_AUTH, POLYGLANCE_ERR_INIT, POLYGLANCE_ERR_INVALID_CONFIG,
    POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_INVALID_RESPONSE, POLYGLANCE_ERR_NETWORK,
    POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_ERR_PROVIDER, POLYGLANCE_ERR_RATE_LIMIT, POLYGLANCE_OK,
    c_char_to_str, ffi_status, ffi_void, string_to_c_char,
};

pub struct TranslationEngine {
    runtime: Arc<Runtime>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct CTranslationInput {
    pub provider: String,
    pub endpoint: String,
    pub api_key: String,
    pub model: String,
    #[serde(default)]
    pub region: Option<String>,
    pub text: String,
    #[serde(default)]
    pub source_language: Option<String>,
    pub target_language: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct CTranslationOutput {
    pub text: String,
    pub provider: String,
    pub elapsed_ms: u64,
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_engine_new(out_engine: *mut *mut TranslationEngine) -> i32 {
    ffi_status(|| unsafe { engine_new(out_engine) })
}

unsafe fn engine_new(out_engine: *mut *mut TranslationEngine) -> i32 {
    if out_engine.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }
    match Builder::new_multi_thread()
        .enable_all()
        .thread_name("polyglance-win")
        .build()
    {
        Ok(runtime) => {
            let engine = Box::new(TranslationEngine {
                runtime: Arc::new(runtime),
            });
            unsafe {
                *out_engine = Box::into_raw(engine);
            }
            POLYGLANCE_OK
        }
        Err(_) => POLYGLANCE_ERR_INIT,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_engine_free(engine: *mut TranslationEngine) {
    ffi_void(|| {
        if !engine.is_null() {
            drop(unsafe { Box::from_raw(engine) });
        }
    });
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_translate(
    engine: *mut TranslationEngine,
    input_json: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe { translate(engine, input_json, out_json) })
}

unsafe fn translate(
    engine: *mut TranslationEngine,
    input_json: *const c_char,
    out_json: *mut *mut c_char,
) -> i32 {
    if engine.is_null() || input_json.is_null() || out_json.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let input_str = match unsafe { c_char_to_str(input_json) } {
        Some(s) => s,
        None => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let input: CTranslationInput = match serde_json::from_str(input_str) {
        Ok(inp) => inp,
        Err(_) => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    let request = match TranslationRequest::new(
        input.text,
        input.source_language.as_deref(),
        &input.target_language,
    ) {
        Ok(req) => req,
        Err(e) => return map_core_error(e),
    };

    let selection =
        match dispatch::select(&input.provider, input.endpoint, input.api_key, input.model) {
            Ok(sel) => sel,
            Err(e) => return map_provider_error(e),
        };

    let engine_ref = unsafe { &*engine };
    let result = match engine_ref
        .runtime
        .block_on(dispatch::translate(selection, &request))
    {
        Ok(res) => res,
        Err(e) => return map_provider_error(e),
    };

    let output = CTranslationOutput {
        text: result.text,
        provider: result.provider,
        elapsed_ms: result.elapsed_ms,
    };

    match serde_json::to_string(&output) {
        Ok(json_str) => {
            unsafe {
                *out_json = string_to_c_char(json_str);
            }
            POLYGLANCE_OK
        }
        Err(_) => POLYGLANCE_ERR_INVALID_RESPONSE,
    }
}

pub const STREAM_EVENT_DELTA: i32 = 1;
pub const STREAM_EVENT_DONE: i32 = 2;
pub const STREAM_EVENT_ERROR: i32 = 3;

pub type StreamCallback =
    extern "C" fn(event_type: i32, data: *const c_char, user_data: *mut c_void);

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_stream_event_parse(
    line: *const c_char,
    out_event_type: *mut i32,
    out_text: *mut *mut c_char,
) -> i32 {
    ffi_status(|| unsafe { stream_event_parse(line, out_event_type, out_text) })
}

unsafe fn stream_event_parse(
    line: *const c_char,
    out_event_type: *mut i32,
    out_text: *mut *mut c_char,
) -> i32 {
    if line.is_null() || out_event_type.is_null() || out_text.is_null() {
        return POLYGLANCE_ERR_NULL_PTR;
    }

    let line_str = match unsafe { c_char_to_str(line) } {
        Some(s) => s,
        None => return POLYGLANCE_ERR_INVALID_INPUT,
    };

    match streaming::stream_event(line_str) {
        Ok(None) => {
            unsafe {
                *out_event_type = 0;
                *out_text = std::ptr::null_mut();
            }
            POLYGLANCE_OK
        }
        Ok(Some(streaming::StreamEvent::Delta(text))) => {
            unsafe {
                *out_event_type = STREAM_EVENT_DELTA;
                *out_text = string_to_c_char(text);
            }
            POLYGLANCE_OK
        }
        Ok(Some(streaming::StreamEvent::Done)) => {
            unsafe {
                *out_event_type = STREAM_EVENT_DONE;
                *out_text = std::ptr::null_mut();
            }
            POLYGLANCE_OK
        }
        Err(streaming::StreamParseError::InvalidResponse) => POLYGLANCE_ERR_INVALID_RESPONSE,
        Err(streaming::StreamParseError::Provider(_)) => POLYGLANCE_ERR_PROVIDER,
    }
}

fn map_core_error(_error: CoreError) -> i32 {
    POLYGLANCE_ERR_INVALID_INPUT
}

fn map_provider_error(error: ProviderError) -> i32 {
    match error {
        ProviderError::InvalidRequest(_) => POLYGLANCE_ERR_INVALID_INPUT,
        ProviderError::InvalidConfig(_) => POLYGLANCE_ERR_INVALID_CONFIG,
        ProviderError::Network(_) => POLYGLANCE_ERR_NETWORK,
        ProviderError::Authentication(_) => POLYGLANCE_ERR_AUTH,
        ProviderError::RateLimited(_) => POLYGLANCE_ERR_RATE_LIMIT,
        ProviderError::Server { .. } => POLYGLANCE_ERR_PROVIDER,
        ProviderError::InvalidResponse(_) => POLYGLANCE_ERR_INVALID_RESPONSE,
    }
}
