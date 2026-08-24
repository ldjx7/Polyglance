using System;
using System.Speech.Synthesis;

namespace Polyglance.UI.Services;

public static class SpeechService
{
    private static readonly Lazy<SpeechSynthesizer> _lazySynth = new(() =>
    {
        var synth = new SpeechSynthesizer();
        synth.SetOutputToDefaultAudioDevice();
        return synth;
    });

    public static void Speak(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return;

        try
        {
            var synth = _lazySynth.Value;
            synth.SpeakAsyncCancelAll();
            synth.SpeakAsync(text.Trim());
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"TTS Error: {ex.Message}");
        }
    }

    public static void Stop()
    {
        try
        {
            if (_lazySynth.IsValueCreated)
            {
                _lazySynth.Value.SpeakAsyncCancelAll();
            }
        }
        catch { }
    }
}
