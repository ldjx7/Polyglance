use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;
use translator_core::TranslationRequest;
use translator_providers::dispatch::{self, FREE_AI, select};

#[tokio::main]
async fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() < 2 || args[1] == "-h" || args[1] == "--help" || args[1] == "help" {
        print_help();
        return ExitCode::SUCCESS;
    }

    let command = args[1].to_lowercase();
    match command.as_str() {
        "version" | "-v" | "--version" => {
            println!("Polyglance Rust CLI {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        "providers" => {
            println!("可用服务商 (Built-in Providers):");
            println!("  - free-ai (默认，无需配置)");
            println!("  - google (内置免费版)");
            println!("  - microsoft (内置免费版)");
            println!("  - deepl (需配置 api-key)");
            println!("  - baidu (需配置 app_id:secret_key)");
            println!("  - youdao (需配置 app_key:secret)");
            println!("  - volcano (需配置 access_key:secret_key)");
            println!("  - openai-compatible (需配置 endpoint 与 api_key)");
            ExitCode::SUCCESS
        }
        "translate" => run_translate(&args[2..]).await,
        "ocr" => run_ocr(&args[2..]).await,
        "model" => run_model(&args[2..]),
        _ => {
            eprintln!("未知命令: {command}");
            print_help();
            ExitCode::FAILURE
        }
    }
}

fn run_model(args: &[String]) -> ExitCode {
    let action = args.first().map(String::as_str).unwrap_or("");
    match action {
        "list" => {
            let directory = model_core::default_model_directory();
            match model_core::list_model_files(&directory) {
                Ok(files) => {
                    for path in files {
                        println!("{}", path.display());
                    }
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("读取模型目录失败: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        "inspect" | "install" => {
            let Some(path) = args.get(1) else {
                eprintln!("请指定 ONNX 模型文件路径");
                return ExitCode::FAILURE;
            };
            let runtime = match model_core::default_runtime_path() {
                Ok(path) => path,
                Err(error) => {
                    eprintln!("寻找 ONNX Runtime 失败: {error}");
                    return ExitCode::FAILURE;
                }
            };
            let path = Path::new(path);
            let is_onnx = path.extension().and_then(|ext| ext.to_str()) == Some("onnx");
            let inputs = if is_onnx {
                match model_core::inspect_model(path, &runtime) {
                    Ok(inputs) => inputs,
                    Err(error) => {
                        eprintln!("模型验证失败: {error}");
                        return ExitCode::FAILURE;
                    }
                }
            } else {
                Vec::new()
            };
            if action == "inspect" {
                println!("输入: {}", inputs.join(", "));
                return ExitCode::SUCCESS;
            }
            match model_core::install_model(path, &model_core::destination_directory_for(path)) {
                Ok(model) => {
                    println!(
                        "已安装 {} (SHA-256: {})",
                        model.file.display(),
                        model.sha256
                    );
                    ExitCode::SUCCESS
                }
                Err(error) => {
                    eprintln!("安装模型失败: {error}");
                    ExitCode::FAILURE
                }
            }
        }
        _ => {
            eprintln!("用法: polyglance-cli model <list|inspect|install> [模型路径]");
            ExitCode::FAILURE
        }
    }
}

async fn run_translate(args: &[String]) -> ExitCode {
    let mut text_parts = Vec::new();
    let mut provider = FREE_AI.to_string();
    let mut target_lang = "zh-CN".to_string();
    let mut source_lang = None;
    let mut endpoint = String::new();
    let mut api_key = String::new();
    let mut model = String::new();

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--provider" | "-p" if i + 1 < args.len() => {
                provider = args[i + 1].clone();
                i += 2;
            }
            "--target" | "-t" if i + 1 < args.len() => {
                target_lang = args[i + 1].clone();
                i += 2;
            }
            "--source" | "-s" if i + 1 < args.len() => {
                source_lang = Some(args[i + 1].clone());
                i += 2;
            }
            "--endpoint" if i + 1 < args.len() => {
                endpoint = args[i + 1].clone();
                i += 2;
            }
            "--api-key" if i + 1 < args.len() => {
                api_key = args[i + 1].clone();
                i += 2;
            }
            "--model" if i + 1 < args.len() => {
                model = args[i + 1].clone();
                i += 2;
            }
            arg if !arg.starts_with('-') => {
                text_parts.push(arg.to_string());
                i += 1;
            }
            unknown => {
                eprintln!("未知选项: {unknown}");
                return ExitCode::FAILURE;
            }
        }
    }

    let text = text_parts.join(" ");
    if text.trim().is_empty() {
        eprintln!("错误: 请指定要翻译的文本内容。");
        return ExitCode::FAILURE;
    }

    let selection = match select(&provider, endpoint, api_key, model) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("配置解析失败: {e}");
            return ExitCode::FAILURE;
        }
    };

    let request = match TranslationRequest::new(&text, source_lang.as_deref(), &target_lang) {
        Ok(req) => req,
        Err(e) => {
            eprintln!("构造翻译请求失败: {e}");
            return ExitCode::FAILURE;
        }
    };

    match dispatch::translate(selection, &request).await {
        Ok(result) => {
            println!("{}", result.text);
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("翻译失败: {e}");
            ExitCode::FAILURE
        }
    }
}

async fn run_ocr(args: &[String]) -> ExitCode {
    if args.is_empty() {
        eprintln!("错误: 请指定图片路径。例如: polyglance-cli ocr test.png");
        return ExitCode::FAILURE;
    }

    let file_path = &args[0];
    let mut engine = if cfg!(windows) { "system" } else { "ppocr" };
    if args.len() > 1 {
        if args.len() != 3 || args[1] != "--engine" {
            eprintln!("用法: polyglance-cli ocr <图片路径> [--engine system|ppocr]");
            return ExitCode::FAILURE;
        }
        engine = &args[2];
    }
    if !Path::new(file_path).exists() {
        eprintln!("错误: 图片文件不存在: {file_path}");
        return ExitCode::FAILURE;
    }

    let bytes = match fs::read(file_path) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("读取图片失败: {e}");
            return ExitCode::FAILURE;
        }
    };

    if engine == "ppocr" {
        return run_ppocr(&bytes);
    }

    #[cfg(windows)]
    {
        if engine != "system" {
            eprintln!("不支持的 OCR 引擎: {engine}");
            return ExitCode::FAILURE;
        }
        match polyglance_cabi::winrt_ocr::recognize_png_bytes(&bytes) {
            Ok(lines) => {
                for line in lines {
                    println!("{}", line.text);
                }
                ExitCode::SUCCESS
            }
            Err(e) => {
                eprintln!("OCR 识别失败: {e}");
                ExitCode::FAILURE
            }
        }
    }

    #[cfg(not(windows))]
    {
        let _ = bytes;
        eprintln!("当前平台的系统 OCR 仅在 Windows 下可用。");
        ExitCode::FAILURE
    }
}

#[cfg(any(windows, target_os = "linux"))]
fn run_ppocr(bytes: &[u8]) -> ExitCode {
    let image = match image::load_from_memory(bytes) {
        Ok(image) => image.to_rgba8(),
        Err(error) => {
            eprintln!("图片解码失败: {error}");
            return ExitCode::FAILURE;
        }
    };
    let runtime = match model_core::default_runtime_path() {
        Ok(path) => path,
        Err(error) => {
            eprintln!("寻找 ONNX Runtime 失败: {error}");
            return ExitCode::FAILURE;
        }
    };
    let mut ocr =
        match model_core::ocr::OnnxOcr::open(&runtime, &model_core::default_model_directory()) {
            Ok(ocr) => ocr,
            Err(error) => {
                eprintln!("加载 PP-OCR 模型失败: {error}");
                return ExitCode::FAILURE;
            }
        };
    match ocr.recognize_rgba(
        image.as_raw(),
        image.width() as usize,
        image.height() as usize,
    ) {
        Ok(text) => {
            println!("{text}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("ONNX OCR 失败: {error}");
            ExitCode::FAILURE
        }
    }
}

#[cfg(not(any(windows, target_os = "linux")))]
fn run_ppocr(_bytes: &[u8]) -> ExitCode {
    eprintln!("ONNX OCR 目前仅支持 Windows 和 Linux。");
    ExitCode::FAILURE
}

fn print_help() {
    println!("Polyglance Rust CLI 命令行工具");
    println!();
    println!("用法:");
    println!("  polyglance-cli <命令> [参数]");
    println!();
    println!("可用命令:");
    println!("  translate <文本> [--provider <服务商>] [--target <目标语言>] [--source <源语言>]");
    println!("  ocr <图片路径> [--engine system|ppocr]");
    println!("  providers");
    println!("  model <list|inspect|install> [模型路径]");
    println!("  version");
}
