//! Streaming H.264 encoding and compressed-video remuxing. All COM objects stay
//! on their owning MTA thread; the synchronous command channel bounds memory.
use crate::{
    POLYGLANCE_ERR_INIT, POLYGLANCE_ERR_INVALID_INPUT, POLYGLANCE_ERR_NULL_PTR, ffi_status,
};
use std::ffi::{c_char, c_void};

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_recording_encoder_new(
    path: *const c_char,
    width: u32,
    height: u32,
    fps: u32,
    bitrate: u32,
    output: *mut *mut c_void,
) -> i32 {
    ffi_status(|| {
        if path.is_null() || output.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }
        unsafe {
            *output = std::ptr::null_mut();
        }
        if width < 2
            || height < 2
            || width % 2 != 0
            || height % 2 != 0
            || width > 16384
            || height > 16384
            || fps == 0
            || fps > 240
            || bitrate == 0
        {
            return POLYGLANCE_ERR_INVALID_INPUT;
        }
        #[cfg(windows)]
        {
            let Some(path) = (unsafe { crate::c_char_to_str(path) }) else {
                return POLYGLANCE_ERR_INVALID_INPUT;
            };
            match implementation::Worker::start(path.to_owned(), width, height, fps, bitrate) {
                Ok(worker) => {
                    unsafe {
                        *output = Box::into_raw(Box::new(worker)).cast();
                    }
                    0
                }
                Err(error) => error,
            }
        }
        #[cfg(not(windows))]
        {
            let _ = (width, height, fps, bitrate);
            POLYGLANCE_ERR_INIT
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_recording_encoder_write(
    handle: *mut c_void,
    pixels: *const u8,
    length: usize,
    timestamp: i64,
) -> i32 {
    ffi_status(|| {
        if handle.is_null() || pixels.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }
        if timestamp < 0 {
            return POLYGLANCE_ERR_INVALID_INPUT;
        }
        #[cfg(windows)]
        {
            let worker = unsafe { &*handle.cast::<implementation::Worker>() };
            if length != worker.frame_bytes {
                return POLYGLANCE_ERR_INVALID_INPUT;
            }
            worker.write(
                unsafe { std::slice::from_raw_parts(pixels, length) }.to_vec(),
                timestamp,
            )
        }
        #[cfg(not(windows))]
        {
            let _ = length;
            POLYGLANCE_ERR_INIT
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_recording_encoder_finish(
    handle: *mut c_void,
    end_time: i64,
) -> i32 {
    ffi_status(|| {
        if handle.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }
        #[cfg(windows)]
        {
            unsafe { &*handle.cast::<implementation::Worker>() }.finish(end_time)
        }
        #[cfg(not(windows))]
        {
            let _ = end_time;
            POLYGLANCE_ERR_INIT
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_recording_encoder_free(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }
    #[cfg(windows)]
    {
        drop(unsafe { Box::from_raw(handle.cast::<implementation::Worker>()) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn polyglance_windows_recording_remux(
    video: *const c_char,
    audio: *const c_char,
    output: *const c_char,
) -> i32 {
    ffi_status(|| {
        if video.is_null() || audio.is_null() || output.is_null() {
            return POLYGLANCE_ERR_NULL_PTR;
        }
        #[cfg(windows)]
        {
            let paths = unsafe {
                (
                    crate::c_char_to_str(video),
                    crate::c_char_to_str(audio),
                    crate::c_char_to_str(output),
                )
            };
            let (Some(video), Some(audio), Some(output)) = paths else {
                return POLYGLANCE_ERR_INVALID_INPUT;
            };
            let (video, audio, output) = (video.to_owned(), audio.to_owned(), output.to_owned());
            std::thread::spawn(move || {
                implementation::remux(&video, &audio, &output)
                    .map(|_| 0)
                    .unwrap_or_else(|e| e.code().0)
            })
            .join()
            .unwrap_or(POLYGLANCE_ERR_INIT)
        }
        #[cfg(not(windows))]
        {
            POLYGLANCE_ERR_INIT
        }
    })
}

#[cfg(windows)]
mod implementation {
    use crate::POLYGLANCE_ERR_INIT;
    use std::sync::mpsc::{self, Sender, SyncSender};
    use std::thread::JoinHandle;
    use windows::Win32::Media::MediaFoundation::*;
    use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx, CoUninitialize};
    use windows::core::{HSTRING, Result};

    struct Runtime;
    impl Runtime {
        fn new() -> Result<Self> {
            unsafe {
                CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
                if let Err(e) = MFStartup(MF_VERSION, MFSTARTUP_FULL) {
                    CoUninitialize();
                    return Err(e);
                }
            }
            Ok(Self)
        }
    }
    impl Drop for Runtime {
        fn drop(&mut self) {
            unsafe {
                let _ = MFShutdown();
                CoUninitialize();
            }
        }
    }

    enum Command {
        Frame(Vec<u8>, i64, Sender<i32>),
        Finish(i64, Sender<i32>),
        Abort,
    }
    pub struct Worker {
        sender: SyncSender<Command>,
        thread: Option<JoinHandle<()>>,
        pub frame_bytes: usize,
    }
    impl Worker {
        pub fn start(
            path: String,
            width: u32,
            height: u32,
            fps: u32,
            bitrate: u32,
        ) -> std::result::Result<Self, i32> {
            let (sender, receiver) = mpsc::sync_channel(1);
            let (ready, initialized) = mpsc::channel();
            let thread = std::thread::spawn(move || {
                let _runtime = match Runtime::new() {
                    Ok(runtime) => runtime,
                    Err(error) => {
                        let _ = ready.send(error.code().0);
                        return;
                    }
                };
                let mut encoder = match Encoder::new(&path, width, height, fps, bitrate) {
                    Ok(encoder) => encoder,
                    Err(error) => {
                        let _ = ready.send(error.code().0);
                        return;
                    }
                };
                let _ = ready.send(0);
                while let Ok(command) = receiver.recv() {
                    match command {
                        Command::Frame(bytes, time, reply) => {
                            let result = encoder
                                .append(bytes, time)
                                .map(|_| 0)
                                .unwrap_or_else(|e| e.code().0);
                            let _ = reply.send(result);
                            if result != 0 {
                                break;
                            }
                        }
                        Command::Finish(time, reply) => {
                            let result = encoder
                                .finish(time)
                                .map(|_| 0)
                                .unwrap_or_else(|e| e.code().0);
                            let _ = reply.send(result);
                            break;
                        }
                        Command::Abort => break,
                    }
                }
            });
            let status = initialized.recv().unwrap_or(POLYGLANCE_ERR_INIT);
            if status != 0 {
                let _ = thread.join();
                return Err(status);
            }
            Ok(Self {
                sender,
                thread: Some(thread),
                frame_bytes: width as usize * height as usize * 4,
            })
        }
        pub fn write(&self, pixels: Vec<u8>, time: i64) -> i32 {
            let (reply, receiver) = mpsc::channel();
            if self
                .sender
                .send(Command::Frame(pixels, time, reply))
                .is_err()
            {
                return POLYGLANCE_ERR_INIT;
            }
            receiver.recv().unwrap_or(POLYGLANCE_ERR_INIT)
        }
        pub fn finish(&self, time: i64) -> i32 {
            let (reply, receiver) = mpsc::channel();
            if self.sender.send(Command::Finish(time, reply)).is_err() {
                return POLYGLANCE_ERR_INIT;
            }
            receiver.recv().unwrap_or(POLYGLANCE_ERR_INIT)
        }
    }
    impl Drop for Worker {
        fn drop(&mut self) {
            let _ = self.sender.send(Command::Abort);
            if let Some(thread) = self.thread.take() {
                let _ = thread.join();
            }
        }
    }

    fn attributes() -> Result<IMFAttributes> {
        let mut attributes = None;
        unsafe {
            MFCreateAttributes(&mut attributes, 4)?;
        }
        Ok(attributes.unwrap())
    }
    fn video_type(
        subtype: &windows::core::GUID,
        width: u32,
        height: u32,
        fps: u32,
    ) -> Result<IMFMediaType> {
        unsafe {
            let ty = MFCreateMediaType()?;
            ty.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            ty.SetGUID(&MF_MT_SUBTYPE, subtype)?;
            ty.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            ty.SetUINT64(&MF_MT_FRAME_SIZE, ((width as u64) << 32) | height as u64)?;
            ty.SetUINT64(&MF_MT_FRAME_RATE, ((fps as u64) << 32) | 1)?;
            ty.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
            Ok(ty)
        }
    }
    struct Encoder {
        writer: IMFSinkWriter,
        stream: u32,
        frame_duration: i64,
        pending: Option<(Vec<u8>, i64)>,
    }
    impl Encoder {
        fn new(path: &str, width: u32, height: u32, fps: u32, bitrate: u32) -> Result<Self> {
            // Hardware is preferred, but unsupported drivers can still use the system encoder.
            Self::create(path, width, height, fps, bitrate, true)
                .or_else(|_| Self::create(path, width, height, fps, bitrate, false))
        }
        fn create(
            path: &str,
            width: u32,
            height: u32,
            fps: u32,
            bitrate: u32,
            hardware: bool,
        ) -> Result<Self> {
            unsafe {
                let attrs = attributes()?;
                attrs.SetUINT32(&MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, hardware as u32)?;
                attrs.SetUINT32(&MF_LOW_LATENCY, 1)?;
                attrs.SetUINT32(&MF_SINK_WRITER_DISABLE_THROTTLING, 1)?;
                let writer = MFCreateSinkWriterFromURL(&HSTRING::from(path), None, &attrs)?;
                let output = video_type(&MFVideoFormat_H264, width, height, fps)?;
                output.SetUINT32(&MF_MT_AVG_BITRATE, bitrate)?;
                output.SetUINT32(&MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main.0 as u32)?;
                let stream = writer.AddStream(&output)?;
                let input = video_type(&MFVideoFormat_RGB32, width, height, fps)?;
                input.SetUINT32(&MF_MT_DEFAULT_STRIDE, width * 4)?;
                writer.SetInputMediaType(stream, &input, None)?;
                writer.BeginWriting()?;
                Ok(Self {
                    writer,
                    stream,
                    frame_duration: 10_000_000 / fps as i64,
                    pending: None,
                })
            }
        }
        fn append(&mut self, pixels: Vec<u8>, time: i64) -> Result<()> {
            if let Some((previous, timestamp)) = self.pending.take() {
                if time <= timestamp {
                    return Err(windows::core::Error::from_hresult(windows::core::HRESULT(
                        0x80070057u32 as i32,
                    )));
                }
                self.write_sample(&previous, timestamp, time - timestamp)?;
            }
            self.pending = Some((pixels, time));
            Ok(())
        }
        fn write_sample(&self, pixels: &[u8], time: i64, duration: i64) -> Result<()> {
            unsafe {
                let buffer = MFCreateMemoryBuffer(pixels.len() as u32)?;
                let mut destination = std::ptr::null_mut();
                buffer.Lock(&mut destination, None, None)?;
                std::ptr::copy_nonoverlapping(pixels.as_ptr(), destination, pixels.len());
                buffer.Unlock()?;
                buffer.SetCurrentLength(pixels.len() as u32)?;
                let sample = MFCreateSample()?;
                sample.AddBuffer(&buffer)?;
                sample.SetSampleTime(time)?;
                sample.SetSampleDuration(duration)?;
                self.writer.WriteSample(self.stream, &sample)
            }
        }
        fn finish(&mut self, end_time: i64) -> Result<()> {
            if let Some((pixels, time)) = self.pending.take() {
                self.write_sample(&pixels, time, (end_time - time).max(self.frame_duration))?;
            }
            unsafe { self.writer.Finalize() }
        }
    }

    fn audio_type(subtype: &windows::core::GUID) -> Result<IMFMediaType> {
        unsafe {
            let ty = MFCreateMediaType()?;
            ty.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
            ty.SetGUID(&MF_MT_SUBTYPE, subtype)?;
            ty.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 2)?;
            ty.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, 48_000)?;
            ty.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
            if *subtype == MFAudioFormat_PCM {
                ty.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, 4)?;
                ty.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 192_000)?;
            } else {
                ty.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, 24_000)?;
            }
            Ok(ty)
        }
    }
    fn read_sample(reader: &IMFSourceReader, index: u32) -> Result<Option<(IMFSample, i64)>> {
        loop {
            let (mut flags, mut time, mut sample) = (0, 0, None);
            unsafe {
                reader.ReadSample(
                    index,
                    0,
                    None,
                    Some(&mut flags),
                    Some(&mut time),
                    Some(&mut sample),
                )?;
            }
            if let Some(sample) = sample {
                return Ok(Some((sample, time)));
            }
            if flags & MF_SOURCE_READERF_ENDOFSTREAM.0 as u32 != 0 {
                return Ok(None);
            }
            if flags & MF_SOURCE_READERF_ERROR.0 as u32 != 0 {
                return Err(windows::core::Error::from_hresult(windows::core::HRESULT(
                    0x80004005u32 as i32,
                )));
            }
        }
    }
    pub fn remux(video: &str, audio: &str, output: &str) -> Result<()> {
        let _runtime = Runtime::new()?;
        unsafe {
            let video_reader = MFCreateSourceReaderFromURL(&HSTRING::from(video), None)?;
            let video_index = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
            video_reader.SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS.0 as u32, false)?;
            video_reader.SetStreamSelection(video_index, true)?;
            let compressed = video_reader.GetNativeMediaType(video_index, 0)?;
            video_reader.SetCurrentMediaType(video_index, None, &compressed)?;
            let audio_reader = MFCreateSourceReaderFromURL(&HSTRING::from(audio), None)?;
            let audio_index = MF_SOURCE_READER_FIRST_AUDIO_STREAM.0 as u32;
            audio_reader.SetCurrentMediaType(
                audio_index,
                None,
                &audio_type(&MFAudioFormat_PCM)?,
            )?;
            let attrs = attributes()?;
            attrs.SetUINT32(&MF_SINK_WRITER_DISABLE_THROTTLING, 1)?;
            let writer = MFCreateSinkWriterFromURL(&HSTRING::from(output), None, &attrs)?;
            let video_stream = writer.AddStream(&compressed)?;
            // Matching H.264 input/output bypasses the video encoder entirely.
            writer.SetInputMediaType(video_stream, &compressed, None)?;
            let audio_stream = writer.AddStream(&audio_type(&MFAudioFormat_AAC)?)?;
            writer.SetInputMediaType(
                audio_stream,
                &audio_reader.GetCurrentMediaType(audio_index)?,
                None,
            )?;
            writer.BeginWriting()?;
            let mut v = read_sample(&video_reader, video_index)?;
            let mut a = read_sample(&audio_reader, audio_index)?;
            while v.is_some() || a.is_some() {
                if v.is_some() && (a.is_none() || v.as_ref().unwrap().1 <= a.as_ref().unwrap().1) {
                    writer.WriteSample(video_stream, &v.take().unwrap().0)?;
                    v = read_sample(&video_reader, video_index)?;
                } else {
                    writer.WriteSample(audio_stream, &a.take().unwrap().0)?;
                    a = read_sample(&audio_reader, audio_index)?;
                }
            }
            writer.Finalize()
        }
    }
    #[cfg(test)]
    mod tests {
        use super::*;
        use std::io::Write;

        fn packets(path: &str) -> Vec<(i64, i64, Vec<u8>)> {
            let _runtime = Runtime::new().unwrap();
            unsafe {
                let reader = MFCreateSourceReaderFromURL(&HSTRING::from(path), None).unwrap();
                let index = MF_SOURCE_READER_FIRST_VIDEO_STREAM.0 as u32;
                let mut packets = Vec::new();
                while let Some((sample, time)) = read_sample(&reader, index).unwrap() {
                    let buffer = sample.ConvertToContiguousBuffer().unwrap();
                    let mut data = std::ptr::null_mut();
                    let mut length = 0;
                    buffer.Lock(&mut data, None, Some(&mut length)).unwrap();
                    let bytes = std::slice::from_raw_parts(data, length as usize).to_vec();
                    buffer.Unlock().unwrap();
                    packets.push((time, sample.GetSampleDuration().unwrap(), bytes));
                }
                packets
            }
        }

        #[test]
        fn remux_preserves_every_h264_packet_and_timestamp() {
            let directory =
                std::env::temp_dir().join(format!("polyglance-remux-test-{}", std::process::id()));
            std::fs::create_dir_all(&directory).unwrap();
            let video = directory.join("video.mp4").to_string_lossy().into_owned();
            let audio = directory.join("audio.wav").to_string_lossy().into_owned();
            let output = directory.join("output.mp4").to_string_lossy().into_owned();
            let worker = Worker::start(video.clone(), 64, 64, 30, 2_000_000).unwrap();
            for index in 0..30 {
                let mut pixels = vec![0u8; 64 * 64 * 4];
                for (n, pixel) in pixels.chunks_exact_mut(4).enumerate() {
                    pixel[2] = if n / 64 < 32 { 255 } else { 0 };
                    pixel[0] = if n / 64 >= 32 { 255 } else { 0 };
                    pixel[1] = (index * 5) as u8;
                }
                assert_eq!(worker.write(pixels, index * 10_000_000 / 30), 0);
            }
            assert_eq!(worker.finish(10_000_000), 0);
            drop(worker);
            let pcm_bytes = 48_000u32 * 4;
            let mut wav = std::fs::File::create(&audio).unwrap();
            wav.write_all(b"RIFF").unwrap();
            wav.write_all(&(36 + pcm_bytes).to_le_bytes()).unwrap();
            wav.write_all(b"WAVEfmt ").unwrap();
            wav.write_all(&16u32.to_le_bytes()).unwrap();
            wav.write_all(&1u16.to_le_bytes()).unwrap();
            wav.write_all(&2u16.to_le_bytes()).unwrap();
            wav.write_all(&48_000u32.to_le_bytes()).unwrap();
            wav.write_all(&192_000u32.to_le_bytes()).unwrap();
            wav.write_all(&4u16.to_le_bytes()).unwrap();
            wav.write_all(&16u16.to_le_bytes()).unwrap();
            wav.write_all(b"data").unwrap();
            wav.write_all(&pcm_bytes.to_le_bytes()).unwrap();
            wav.write_all(&vec![0; pcm_bytes as usize]).unwrap();
            drop(wav);
            remux(&video, &audio, &output).unwrap();
            let before = packets(&video);
            let after = packets(&output);
            assert_eq!(before.len(), 30);
            assert_eq!(
                before, after,
                "remux must not re-encode or retime the video"
            );
            assert_eq!(before[0].0, 0);
            for pair in before.windows(2) {
                assert!(pair[1].0 > pair[0].0);
            }
            // 文件保留到测试结束，便于失败时定位；成功后完整清理。
            std::fs::remove_dir_all(directory).unwrap();
        }
    }
}
