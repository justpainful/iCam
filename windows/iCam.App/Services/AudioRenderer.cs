using System.Runtime.InteropServices;
using ICam.Core.Protocol;
using WinRT;
using Windows.Devices.Enumeration;
using Windows.Media;
using Windows.Media.Audio;
using Windows.Media.MediaProperties;
using Windows.Media.Render;

namespace ICam.App.Services;

/// <summary>
/// Plays the iPhone's microphone into a Windows render device.
///
/// This is the microphone half of "connect the phone and it appears in
/// Discord". Windows has no supported way to create a virtual *audio* device
/// from user mode — that genuinely requires a signed kernel driver, which is
/// why the products that ship one ship an installer for it. What Windows does
/// have is loopback cables: if VB-Audio's CABLE (or anything like it) is
/// installed, iCam plays the phone's microphone into <c>CABLE Input</c> and
/// every application on the machine can select <c>CABLE Output</c> as its
/// microphone. No cable installed? The audio goes to the default speakers so
/// the user can at least hear that the path works, and the interface says
/// what to install to finish the job.
///
/// The graph is built lazily from the first audio frame, because the format
/// belongs to the phone: it says 48 kHz mono or 44.1 stereo, and building the
/// input node around anything else means resampling artifacts nobody ordered.
/// </summary>
public sealed class AudioRenderer : IAsyncDisposable
{
    /// <summary>
    /// Above this much queued audio the renderer is running behind the phone,
    /// and a microphone that drifts out of sync is worse than one that clicks
    /// once. The backlog is dropped and the stream continues live.
    /// </summary>
    private const double MaxBufferedSeconds = 0.25;

    private readonly Lock _lock = new();

    private AudioGraph? _graph;
    private AudioFrameInputNode? _input;
    private AudioDeviceOutputNode? _output;
    private uint _sampleRate;
    private byte _channels;
    private bool _building;
    private double _bufferedSeconds;

    public ulong FramesRendered { get; private set; }
    public ulong FramesDropped { get; private set; }

    /// <summary>The render device in use, for the interface to name.</summary>
    public string? ActiveDeviceName { get; private set; }

    /// <summary>True when the audio lands in a loopback cable other apps can use as a mic.</summary>
    public bool IsFeedingCable { get; private set; }

    public event Action? StateChanged;

    /// <summary>
    /// Called for every audio frame off the network thread. Cheap when the
    /// graph exists; the first call starts the build and drops frames until it
    /// finishes, which is the right trade — a microphone missing its first
    /// half-second is unremarkable, a network thread blocked on device
    /// enumeration is not.
    /// </summary>
    public void Render(AudioFrameHeader header, ReadOnlyMemory<byte> pcm)
    {
        if (header.Codec != AudioCodec.PcmS16Le || header.Channels is 0 or > 2) return;

        lock (_lock)
        {
            if (_graph is null || _sampleRate != header.SampleRate
                               || _channels != header.Channels)
            {
                if (!_building)
                {
                    _building = true;
                    var rate = header.SampleRate;
                    var channels = header.Channels;
                    _ = Task.Run(() => BuildAsync(rate, channels));
                }
                FramesDropped++;
                return;
            }

            if (_bufferedSeconds > MaxBufferedSeconds)
            {
                // Late is forever for live audio. Drop and stay current.
                FramesDropped++;
                return;
            }

            Push(pcm.Span, header.Channels);
            FramesRendered++;
        }
    }

    /// <summary>Reused between frames; a microphone produces fifty a second.</summary>
    private float[] _scratch = [];

    private void Push(ReadOnlySpan<byte> pcm, int channels)
    {
        var samples = pcm.Length / 2;
        if (samples == 0 || _input is null) return;

        if (_scratch.Length < samples) _scratch = new float[samples];
        var source = MemoryMarshal.Cast<byte, short>(pcm[..(samples * 2)]);
        for (var i = 0; i < samples; i++)
        {
            _scratch[i] = source[i] / 32768f;
        }

        using var frame = new AudioFrame((uint)(samples * sizeof(float)));
        using (var buffer = frame.LockBuffer(AudioBufferAccessMode.Write))
        using (var reference = buffer.CreateReference())
        {
            // The one COM interface this class needs: the documented way to
            // reach a WinRT media buffer's bytes without an unsafe block.
            var access = reference.As<IMemoryBufferByteAccess>();
            access.GetBuffer(out var pointer, out var capacity);
            var bytes = Math.Min((uint)(samples * sizeof(float)), capacity);
            Marshal.Copy(_scratch, 0, pointer, (int)(bytes / sizeof(float)));
        }

        _input.AddFrame(frame);
        _bufferedSeconds += (double)(samples / channels) / _sampleRate;
    }

    [System.Runtime.InteropServices.ComImport]
    [System.Runtime.InteropServices.Guid("5B0D3235-4DBA-4D44-865E-8F1D0E4FD04D")]
    [System.Runtime.InteropServices.InterfaceType(
        System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMemoryBufferByteAccess
    {
        void GetBuffer(out IntPtr buffer, out uint capacity);
    }

    private async Task BuildAsync(uint sampleRate, byte channels)
    {
        try
        {
            var previous = TearDownLocked();
            previous?.Dispose();

            var device = await PickDeviceAsync().ConfigureAwait(false);

            var settings = new AudioGraphSettings(AudioRenderCategory.Media)
            {
                QuantumSizeSelectionMode = QuantumSizeSelectionMode.LowestLatency,
                PrimaryRenderDevice = device.Information,
            };

            var creation = await AudioGraph.CreateAsync(settings).AsTask().ConfigureAwait(false);
            if (creation.Status != AudioGraphCreationStatus.Success)
            {
                Log.Media.Warn($"No audio graph: {creation.Status}");
                return;
            }

            var graph = creation.Graph;
            var outputResult = await graph.CreateDeviceOutputNodeAsync()
                                          .AsTask().ConfigureAwait(false);
            if (outputResult.Status != AudioDeviceNodeCreationStatus.Success)
            {
                Log.Media.Warn($"No audio output: {outputResult.Status}");
                graph.Dispose();
                return;
            }

            // Float, because that is the only encoding a frame input node
            // accepts; the graph converts to whatever the device runs at.
            var input = graph.CreateFrameInputNode(
                AudioEncodingProperties.CreatePcm(sampleRate, channels, 32));
            input.AddOutgoingConnection(outputResult.DeviceOutputNode);

            graph.QuantumStarted += (g, _) =>
            {
                lock (_lock)
                {
                    _bufferedSeconds = Math.Max(
                        0, _bufferedSeconds - (double)g.SamplesPerQuantum / g.EncodingProperties.SampleRate);
                }
            };

            graph.Start();

            lock (_lock)
            {
                _graph = graph;
                _input = input;
                _output = outputResult.DeviceOutputNode;
                _sampleRate = sampleRate;
                _channels = channels;
                _bufferedSeconds = 0;
                _building = false;
            }

            ActiveDeviceName = device.Information?.Name ?? "Default output";
            IsFeedingCable = device.IsCable;
            Log.Media.Info(device.IsCable
                ? $"iPhone microphone → {ActiveDeviceName}. Select the cable's " +
                  "output as the microphone in any application."
                : $"iPhone microphone → {ActiveDeviceName} (no loopback cable found; " +
                  "install VB-CABLE to use the iPhone as a microphone in other apps)");
            StateChanged?.Invoke();
        }
        catch (Exception error)
        {
            Log.Media.Error("The audio path could not start", error);
            lock (_lock) _building = false;
        }
    }

    private sealed record RenderTarget(DeviceInformation? Information, bool IsCable);

    /// <summary>
    /// A loopback cable if one is installed, the default render device
    /// otherwise. The cable is the whole point — it is what turns "iCam plays
    /// audio" into "Discord has a microphone".
    /// </summary>
    private static async Task<RenderTarget> PickDeviceAsync()
    {
        var devices = await DeviceInformation
            .FindAllAsync(DeviceClass.AudioRender).AsTask().ConfigureAwait(false);

        var cable = devices.FirstOrDefault(d =>
            d.Name.Contains("CABLE Input", StringComparison.OrdinalIgnoreCase) ||
            d.Name.Contains("VB-Audio", StringComparison.OrdinalIgnoreCase) ||
            d.Name.Contains("Virtual Cable", StringComparison.OrdinalIgnoreCase));

        return cable is not null
            ? new RenderTarget(cable, true)
            : new RenderTarget(null, false); // null = the graph uses the default device
    }

    private AudioGraph? TearDownLocked()
    {
        lock (_lock)
        {
            var graph = _graph;
            _graph = null;
            _input = null;
            _output = null;
            return graph;
        }
    }

    public ValueTask DisposeAsync()
    {
        var graph = TearDownLocked();
        graph?.Stop();
        graph?.Dispose();
        return ValueTask.CompletedTask;
    }
}
