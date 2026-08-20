using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Xml.Linq;

namespace ICam.Core.Transport;

/// <summary>
/// A client for Apple's USB multiplexing service — the piece of iTunes that
/// every "connect your iPhone with a cable" feature on Windows is built on.
///
/// The service listens on TCP 127.0.0.1:27015 and speaks a tiny protocol:
/// sixteen-byte little-endian headers carrying XML property lists. One
/// long-lived connection plays <c>Listen</c> and receives Attached/Detached
/// events as phones come and go; a fresh connection per tunnel plays
/// <c>Connect</c>, and on success that socket *becomes* a raw byte pipe to a
/// TCP port on the phone — over the cable, no network anywhere.
///
/// iCam uses it for exactly one thing: reaching the phone's iCam listener over
/// USB. Everything above the tunnel — handshake, trust, encryption — is the
/// same protocol as Wi-Fi, because a transport should not get to change the
/// security story.
/// </summary>
public static class Usbmux
{
    /// <summary>Where Apple Mobile Device Service listens on Windows.</summary>
    public const int ServicePort = 27015;

    /// <summary>The phone-side iCam listener reached through the tunnel.</summary>
    public const ushort PhonePort = 48214;

    private const uint HeaderSize = 16;
    private const uint MessagePlist = 8;

    public sealed record Device(ulong Id, string Serial);

    /// <summary>
    /// Watches for iPhones on the cable. Yields an event per change until the
    /// token is cancelled or the service goes away (no iTunes, no service —
    /// the caller decides how loudly to say so).
    /// </summary>
    public static async IAsyncEnumerable<(Device Device, bool Attached)> WatchAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken token)
    {
        using var client = new TcpClient();
        await client.ConnectAsync("127.0.0.1", ServicePort, token).ConfigureAwait(false);
        var stream = client.GetStream();

        await SendAsync(stream, Plist(
            ("MessageType", "Listen"),
            ("ClientVersionString", "iCam"),
            ("ProgName", "iCam"),
            ("kLibUSBMuxVersion", 3)), token).ConfigureAwait(false);

        while (!token.IsCancellationRequested)
        {
            var message = await ReceiveAsync(stream, token).ConfigureAwait(false);
            if (message is null) yield break;

            switch (Value(message, "MessageType"))
            {
                case "Attached":
                    var properties = message.Elements("key")
                        .FirstOrDefault(k => k.Value == "Properties")
                        ?.ElementsAfterSelf().FirstOrDefault();
                    if (properties is null) break;
                    if (Value(properties, "ConnectionType") != "USB") break;
                    if (!ulong.TryParse(Value(properties, "DeviceID"), out var id)) break;
                    yield return (new Device(id, Value(properties, "SerialNumber") ?? ""), true);
                    break;

                case "Detached":
                    if (ulong.TryParse(Value(message, "DeviceID"), out var gone))
                    {
                        yield return (new Device(gone, ""), false);
                    }
                    break;
            }
        }
    }

    /// <summary>
    /// Opens a tunnel to a TCP port on the given phone. On success the
    /// returned stream is a transparent byte pipe over the cable; disposing it
    /// closes the tunnel.
    /// </summary>
    public static async Task<Stream> ConnectAsync(ulong deviceId, ushort port,
                                                  CancellationToken token)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            await client.ConnectAsync("127.0.0.1", ServicePort, token).ConfigureAwait(false);
            var stream = client.GetStream();

            // The port travels in network byte order inside a little-endian
            // protocol — a historical wart every usbmuxd client carries.
            var swapped = (ushort)((port << 8) | (port >> 8));
            await SendAsync(stream, Plist(
                ("MessageType", "Connect"),
                ("DeviceID", (long)deviceId),
                ("PortNumber", swapped),
                ("ProgName", "iCam")), token).ConfigureAwait(false);

            var reply = await ReceiveAsync(stream, token).ConfigureAwait(false)
                ?? throw new IOException("The USB service closed the connection");
            var result = Value(reply, "Number");
            if (result != "0")
            {
                throw new IOException($"The phone refused the USB tunnel (usbmuxd {result}). " +
                                      "Is iCam open on the iPhone?");
            }

            return stream;
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    // MARK: - Wire format

    private static async Task SendAsync(Stream stream, string plist, CancellationToken token)
    {
        var body = Encoding.UTF8.GetBytes(plist);
        var frame = new byte[HeaderSize + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(frame, (uint)frame.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(8), MessagePlist);
        BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(12), 1);
        body.CopyTo(frame, (int)HeaderSize);
        await stream.WriteAsync(frame, token).ConfigureAwait(false);
    }

    /// <summary>The top-level dict of the next message, or null on a closed stream.</summary>
    private static async Task<XElement?> ReceiveAsync(Stream stream, CancellationToken token)
    {
        var header = new byte[HeaderSize];
        if (!await FillAsync(stream, header, token).ConfigureAwait(false)) return null;

        var length = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (length < HeaderSize || length > 1 << 20)
        {
            throw new IOException("The USB service sent a malformed frame");
        }

        var body = new byte[length - HeaderSize];
        if (!await FillAsync(stream, body, token).ConfigureAwait(false)) return null;

        var document = XDocument.Parse(Encoding.UTF8.GetString(body));
        return document.Root?.Element("dict");
    }

    private static async Task<bool> FillAsync(Stream stream, byte[] buffer,
                                              CancellationToken token)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var chunk = await stream.ReadAsync(buffer.AsMemory(read), token)
                                    .ConfigureAwait(false);
            if (chunk == 0) return false;
            read += chunk;
        }
        return true;
    }

    /// <summary>The value after the given key in a plist dict, as text.</summary>
    private static string? Value(XElement dict, string key) =>
        dict.Elements("key")
            .FirstOrDefault(k => k.Value == key)
            ?.ElementsAfterSelf().FirstOrDefault()?.Value;

    private static string Plist(params (string Key, object Value)[] entries)
    {
        var builder = new StringBuilder(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " +
            "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
            "<plist version=\"1.0\"><dict>");
        foreach (var (key, value) in entries)
        {
            builder.Append("<key>").Append(key).Append("</key>");
            builder.Append(value switch
            {
                string text => $"<string>{text}</string>",
                long number => $"<integer>{number}</integer>",
                int number => $"<integer>{number}</integer>",
                ushort number => $"<integer>{number}</integer>",
                _ => throw new ArgumentException($"No plist form for {value.GetType()}"),
            });
        }
        return builder.Append("</dict></plist>").ToString();
    }
}
