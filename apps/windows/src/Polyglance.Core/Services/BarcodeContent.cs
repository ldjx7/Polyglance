using System.Text;

namespace Polyglance.Core.Services;

/// <summary>
/// What a decoded payload actually means, which decides which actions the
/// result window offers.
/// </summary>
/// <remarks>
/// The classification order matters: the specific payload shapes are tested
/// before the generic text fallback, and anything that is not plain web
/// content deliberately gets no "open" action, because a barcode is a classic
/// phishing carrier.
/// </remarks>
public abstract record BarcodeContent
{
    public sealed record Url(Uri Uri) : BarcodeContent;
    public sealed record Otp(Uri Uri) : BarcodeContent;
    public sealed record Wifi(string Ssid, string? Password, string? Security) : BarcodeContent;
    public sealed record Text(string Value) : BarcodeContent;

    public static BarcodeContent From(string payload)
    {
        var trimmed = payload.Trim();

        if (trimmed.StartsWith(WifiPayload.Prefix, StringComparison.OrdinalIgnoreCase)
            && WifiPayload.TryParse(trimmed, out var wifi))
        {
            return new Wifi(wifi.Ssid, wifi.Password, wifi.Security);
        }

        if (Uri.TryCreate(trimmed, UriKind.Absolute, out var uri))
        {
            var scheme = uri.Scheme.ToLowerInvariant();
            if (scheme == "otpauth")
            {
                return new Otp(uri);
            }
            // Only http(s) is openable. `file:`, `smb:` and custom schemes fall
            // through to text so they never get an "open" button.
            if (scheme is "http" or "https")
            {
                return new Url(uri);
            }
        }

        return new Text(payload);
    }

    /// <summary>
    /// Only plain web links may ever be offered an "open" action.
    /// </summary>
    public bool IsOpenable => this is Url;

    /// <summary>
    /// QR results intentionally stay a lightweight copy/open workflow. Text
    /// translation belongs to the dedicated OCR and screenshot translation
    /// tools, where the user explicitly asks for language processing.
    /// </summary>
    public bool IsTranslatable => false;

    public string CopiedText => this switch
    {
        Url url => url.Uri.AbsoluteUri,
        Otp otp => otp.Uri.AbsoluteUri,
        Wifi wifi => wifi.Password ?? "",
        Text text => text.Value,
        _ => ""
    };
}

/// <summary>
/// A parsed <c>WIFI:</c> payload.
/// </summary>
/// <remarks>
/// The format is <c>WIFI:T:WPA;S:ssid;P:password;;</c> where <c>;</c> separates
/// fields but <c>\,</c> <c>\;</c> <c>\:</c> <c>\\</c> (and <c>\"</c>) inside
/// values are backslash escapes. Splitting naively on <c>;</c> corrupts any
/// network or password containing one of those characters.
/// </remarks>
internal readonly record struct WifiPayload(string Ssid, string? Password, string? Security)
{
    public const string Prefix = "WIFI:";

    private static readonly char[] EscapableCharacters = ['\\', ';', ':', ',', '"'];

    public static bool TryParse(string payload, out WifiPayload result)
    {
        result = default;
        if (!payload.StartsWith(Prefix, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        var body = payload[Prefix.Length..];

        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        var key = new StringBuilder();
        var value = new StringBuilder();
        var readingKey = true;

        void FlushField()
        {
            if (key.Length > 0)
            {
                fields[key.ToString().ToUpperInvariant()] = value.ToString();
            }
            key.Clear();
            value.Clear();
            readingKey = true;
        }

        var index = 0;
        while (index < body.Length)
        {
            var character = body[index];

            if (character == '\\' && index + 1 < body.Length)
            {
                var escaped = body[index + 1];
                var target = readingKey ? key : value;
                if (Array.IndexOf(EscapableCharacters, escaped) >= 0)
                {
                    target.Append(escaped);
                }
                else
                {
                    // An unknown escape keeps both characters verbatim rather
                    // than silently dropping the backslash from the password.
                    target.Append('\\');
                    target.Append(escaped);
                }
                index += 2;
                continue;
            }

            if (readingKey && character == ':')
            {
                readingKey = false;
                index++;
                continue;
            }

            if (!readingKey && character == ';')
            {
                FlushField();
                index++;
                continue;
            }

            (readingKey ? key : value).Append(character);
            index++;
        }
        FlushField();

        if (!fields.TryGetValue("S", out var ssid) || ssid.Length == 0)
        {
            return false;
        }
        fields.TryGetValue("P", out var password);
        fields.TryGetValue("T", out var security);
        result = new WifiPayload(ssid, password, security);
        return true;
    }
}
