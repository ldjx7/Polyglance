use crate::{POLYGLANCE_ERR_NULL_PTR, ffi_status};
use std::ffi::c_char;

#[cfg(not(windows))]
use crate::POLYGLANCE_ERR_INIT;

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_recording_compose(
    video_path: *const c_char,
    audio_paths_json: *const c_char,
    output_path: *const c_char,
    width: i32,
    height: i32,
    frame_rate: i32,
    video_bitrate: u32,
) -> i32 {
    ffi_status(|| {
        if video_path.is_null() || audio_paths_json.is_null() || output_path.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }

        #[cfg(windows)]
        {
            unsafe {
                windows_impl::compose(
                    video_path,
                    audio_paths_json,
                    output_path,
                    width,
                    height,
                    frame_rate,
                    video_bitrate,
                )
            }
        }

        #[cfg(not(windows))]
        {
            let _ = (
                video_path,
                audio_paths_json,
                output_path,
                width,
                height,
                frame_rate,
                video_bitrate,
            );
            POLYGLANCE_ERR_INIT
        }
    })
}

#[cfg(windows)]
mod windows_impl {
    use crate::{
        POLYGLANCE_ERR_INIT, POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, POLYGLANCE_OK,
        c_char_to_str,
    };
    use std::ffi::c_char;
    use std::path::Path;
    use windows::Media::Editing::{
        BackgroundAudioTrack, MediaClip, MediaComposition, MediaTrimmingPreference,
    };
    use windows::Media::MediaProperties::{
        AudioEncodingProperties, MediaEncodingProfile, VideoEncodingQuality,
    };
    use windows::Media::Transcoding::{MediaTranscoder, TranscodeFailureReason};
    use windows::Storage::{CreationCollisionOption, FileAccessMode, StorageFile, StorageFolder};
    use windows::core::HSTRING;

    pub unsafe fn compose(
        video_path: *const c_char,
        audio_paths_json: *const c_char,
        output_path: *const c_char,
        width: i32,
        height: i32,
        frame_rate: i32,
        video_bitrate: u32,
    ) -> i32 {
        let video_str = match unsafe { c_char_to_str(video_path) } {
            Some(s) => s,
            None => return POLYGLANCE_ERR_NULL_PTR,
        };
        let audio_json_str = match unsafe { c_char_to_str(audio_paths_json) } {
            Some(s) => s,
            None => return POLYGLANCE_ERR_NULL_PTR,
        };
        let output_str = match unsafe { c_char_to_str(output_path) } {
            Some(s) => s,
            None => return POLYGLANCE_ERR_NULL_PTR,
        };

        let audio_paths: Vec<String> = match serde_json::from_str(audio_json_str) {
            Ok(v) => v,
            Err(_) => return POLYGLANCE_ERR_INVALID_INPUT,
        };

        let v_str = video_str.to_string();
        let out_str = output_str.to_string();
        let worker = std::thread::spawn(move || {
            run_compose(
                &v_str,
                &audio_paths,
                &out_str,
                width,
                height,
                frame_rate,
                video_bitrate,
            )
        });

        match worker.join() {
            Ok(Ok(())) => POLYGLANCE_OK,
            _ => POLYGLANCE_ERR_INIT,
        }
    }

    fn run_compose(
        video_path: &str,
        audio_paths: &[String],
        output_path: &str,
        width: i32,
        height: i32,
        frame_rate: i32,
        video_bitrate: u32,
    ) -> Result<(), String> {
        let abs_video = std::fs::canonicalize(video_path)
            .map_err(|e| format!("Canonicalize video failed: {e}"))?;
        let video_clean = abs_video
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .to_string();
        let video_hstring = HSTRING::from(video_clean.as_str());

        let video_file = StorageFile::GetFileFromPathAsync(&video_hstring)
            .map_err(|e| format!("GetFileFromPathAsync failed: {e}"))?
            .get()
            .map_err(|e| format!("Get video file failed: {e}"))?;

        let composition =
            MediaComposition::new().map_err(|e| format!("MediaComposition new failed: {e}"))?;

        let clip = MediaClip::CreateFromFileAsync(&video_file)
            .map_err(|e| format!("CreateFromFileAsync clip failed: {e}"))?
            .get()
            .map_err(|e| format!("Get clip failed: {e}"))?;

        let clips = composition
            .Clips()
            .map_err(|e| format!("Get clips failed: {e}"))?;
        clips
            .Append(&clip)
            .map_err(|e| format!("Append clip failed: {e}"))?;

        for audio_path in audio_paths {
            if let Ok(abs_audio) = std::fs::canonicalize(audio_path) {
                let audio_clean = abs_audio
                    .to_string_lossy()
                    .trim_start_matches(r"\\?\")
                    .to_string();
                let audio_hstring = HSTRING::from(audio_clean.as_str());
                if let Ok(audio_file_op) = StorageFile::GetFileFromPathAsync(&audio_hstring) {
                    if let Ok(audio_file) = audio_file_op.get() {
                        if let Ok(track_op) = BackgroundAudioTrack::CreateFromFileAsync(&audio_file)
                        {
                            if let Ok(track) = track_op.get() {
                                if let Ok(tracks) = composition.BackgroundAudioTracks() {
                                    let _ = tracks.Append(&track);
                                }
                            }
                        }
                    }
                }
            }
        }

        let out_p = Path::new(output_path);
        let parent = out_p.parent().ok_or("Invalid output path")?;
        std::fs::create_dir_all(parent).map_err(|e| format!("Create dir failed: {e}"))?;
        let abs_parent = std::fs::canonicalize(parent)
            .map_err(|e| format!("Canonicalize parent failed: {e}"))?;
        let parent_clean = abs_parent
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .to_string();
        let parent_hstring = HSTRING::from(parent_clean.as_str());

        let folder = StorageFolder::GetFolderFromPathAsync(&parent_hstring)
            .map_err(|e| format!("GetFolderFromPathAsync failed: {e}"))?
            .get()
            .map_err(|e| format!("Get folder failed: {e}"))?;

        let file_name = out_p
            .file_name()
            .ok_or("Invalid file name")?
            .to_string_lossy();
        let file_name_hstring = HSTRING::from(file_name.as_ref());

        let output_file = folder
            .CreateFileAsync(&file_name_hstring, CreationCollisionOption::ReplaceExisting)
            .map_err(|e| format!("CreateFileAsync failed: {e}"))?
            .get()
            .map_err(|e| format!("Get output file failed: {e}"))?;

        let profile = MediaEncodingProfile::CreateMp4(VideoEncodingQuality::Auto)
            .map_err(|e| format!("CreateMp4 failed: {e}"))?;

        let w = std::cmp::max(2, width - width % 2) as u32;
        let h = std::cmp::max(2, height - height % 2) as u32;
        if let Ok(video_props) = profile.Video() {
            let _ = video_props.SetWidth(w);
            let _ = video_props.SetHeight(h);
            let _ = video_props.SetBitrate(video_bitrate);
            if let Ok(fr) = video_props.FrameRate() {
                let _ = fr.SetNumerator(std::cmp::max(1, frame_rate) as u32);
                let _ = fr.SetDenominator(1);
            }
        }

        if audio_paths.is_empty() {
            let _ = profile.SetAudio(None);
        } else if let Ok(audio_props) = AudioEncodingProperties::CreateAac(48_000, 2, 192_000) {
            let _ = profile.SetAudio(&audio_props);
        }

        // 优先使用硬件编码；设备或驱动不支持时回退到原有合成路径。
        if transcode_accelerated(&composition, &output_file, &profile).is_ok() {
            return Ok(());
        }

        let render_op = composition
            .RenderToFileWithProfileAsync(&output_file, MediaTrimmingPreference::Precise, &profile)
            .map_err(|e| format!("RenderToFileWithProfileAsync failed: {e}"))?;
        let result = render_op
            .get()
            .map_err(|e| format!("Render get failed: {e}"))?;

        if result != TranscodeFailureReason::None {
            return Err(format!("Render failed with reason: {result:?}"));
        }

        Ok(())
    }
    fn transcode_accelerated(
        composition: &MediaComposition,
        output_file: &StorageFile,
        profile: &MediaEncodingProfile,
    ) -> windows::core::Result<()> {
        let source = composition.GenerateMediaStreamSource()?;
        let output = output_file.OpenAsync(FileAccessMode::ReadWrite)?.get()?;
        let result = (|| {
            output.SetSize(0)?;
            let transcoder = MediaTranscoder::new()?;
            transcoder.SetHardwareAccelerationEnabled(true)?;
            let prepared = transcoder
                .PrepareMediaStreamSourceTranscodeAsync(&source, &output, profile)?
                .get()?;
            if !prepared.CanTranscode()? {
                return Err(windows::core::Error::from_hresult(windows::core::HRESULT(
                    0x80004005u32 as i32,
                )));
            }
            prepared.TranscodeAsync()?.get()
        })();
        // 先释放输出文件，确保回退合成不会与当前流争用文件句柄。
        let closed = output.Close();
        result.and(closed)
    }
}
