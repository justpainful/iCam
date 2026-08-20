using System.Collections.ObjectModel;
using ICam.Core.Media;
using ICam.Core.Protocol;
using ICam.Core.Transport;
using Microsoft.UI.Dispatching;

namespace ICam.App.Services;

/// <summary>
/// One connected iPhone, as the interface sees it.
///
/// Holds the last camera state the phone sent. Windows never treats this as
/// authoritative — it renders it and sends mutations. The phone owns the state,
/// because only the phone can see what the hardware actually accepted.
/// </summary>
public sealed partial class ConnectedDevice : System.ComponentModel.INotifyPropertyChanged
{
    private readonly DispatcherQueue _dispatcher;

    public PeerSession Session { get; }
    public VideoPipeline Video { get; } = new();

    /// <summary>
    /// The image controls, applied on this computer to every decoded frame on
    /// its way to the preview and to <c>iCam Camera</c> — and to nothing else.
    /// The phone's master recording never sees them, which is the rule in
    /// <c>docs/ARCHITECTURE.md</c>, and doing the work on a machine that is
    /// plugged into a wall keeps it off the phone's battery.
    /// </summary>
    public ImageAdjuster Image { get; } = new();

    private string _name = "iPhone";
    private CameraState _state = new();
    private CameraCapabilities _capabilities = new();
    private TelemetryPayload? _telemetry;
    private PeerSession.SessionState _sessionState = PeerSession.SessionState.Handshaking;
    private StreamProfile _streamProfile = StreamProfile.Webcam1080p30;
    private bool _isStreaming;

    /// <summary>
    /// The geometry the video thread works in.
    ///
    /// The same value as <see cref="StreamProfile"/>, kept separately because
    /// the two are read from different threads and only one of them can afford
    /// to wait. The property is written on the dispatcher so the interface can
    /// bind to it; this field is written on the network read loop, before
    /// anything is told that the format changed, so the parameter sets for a
    /// new resolution cannot arrive while it still holds the old one.
    ///
    /// A whole profile rather than two integers: the record is immutable and
    /// the reference publishes atomically, so a reader can never pair a new
    /// width with a stale height.
    /// </summary>
    private volatile StreamProfile _videoFormat = StreamProfile.Webcam1080p30;

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;

    public ConnectedDevice(PeerSession session, DispatcherQueue dispatcher)
    {
        Session = session;
        _dispatcher = dispatcher;

        session.ControlReceived += OnControl;
        session.VideoReceived += OnVideo;
        session.StateChanged += state => Post(() => SessionState = state);
    }

    public string Name
    {
        get => _name;
        private set => Set(ref _name, value);
    }

    public CameraState State
    {
        get => _state;
        private set => Set(ref _state, value);
    }

    public CameraCapabilities Capabilities
    {
        get => _capabilities;
        private set => Set(ref _capabilities, value);
    }

    public TelemetryPayload? Telemetry
    {
        get => _telemetry;
        private set => Set(ref _telemetry, value);
    }

    public PeerSession.SessionState SessionState
    {
        get => _sessionState;
        private set => Set(ref _sessionState, value);
    }

    public StreamProfile StreamProfile
    {
        get => _streamProfile;
        private set => Set(ref _streamProfile, value);
    }

    public bool IsStreaming
    {
        get => _isStreaming;
        private set => Set(ref _isStreaming, value);
    }

    /// <summary>
    /// The recording as the phone last described it, or null when nothing is
    /// recording. The phone is the only writer of this — the record button
    /// here only *asks*, and the chip follows what actually happened, so a
    /// recording started on the phone shows up on this screen too.
    /// </summary>
    public RecordStatePayload? Recording
    {
        get => _recording;
        private set
        {
            _recording = value;
            _recordingUpdatedAtMs = Environment.TickCount64;
            PropertyChanged?.Invoke(this,
                new System.ComponentModel.PropertyChangedEventArgs(nameof(Recording)));
        }
    }
    private RecordStatePayload? _recording;
    private long _recordingUpdatedAtMs;

    /// <summary>
    /// The elapsed time to show right now: the phone's last word plus however
    /// long ago it said it, so the readout ticks smoothly between messages.
    /// </summary>
    public ulong RecordingElapsedUs =>
        Recording is { Recording: true } state
            ? state.ElapsedUs + (ulong)Math.Max(0, Environment.TickCount64 - _recordingUpdatedAtMs) * 1000
            : 0;

    public string? PairingDigits => Session.PairingDigits;
    public string Id => Session.PeerFingerprint ?? "";

    /// <summary>
    /// Sends one mutation, tagged with the state version this computer was
    /// looking at. The phone decides what actually happens; see
    /// <c>docs/PROTOCOL.md</c> section 5.4.
    /// </summary>
    public ValueTask ApplyAsync(CameraMutation mutation) =>
        Session.SendCameraCommandAsync(State.Version, mutation);

    public async Task StartStreamingAsync(StreamProfile profile)
    {
        // Before the request goes out, not after: the phone can have frames on
        // the wire before this await returns.
        _videoFormat = profile;
        await Session.StartStreamAsync(profile);
        Post(() =>
        {
            StreamProfile = profile;
            IsStreaming = true;
        });
    }

    public async Task StopStreamingAsync()
    {
        await Session.StopStreamAsync();
        Video.Reset();
        Post(() => IsStreaming = false);
    }

    private void OnControl(ControlEnvelope envelope)
    {
        switch (envelope.T)
        {
            case ControlType.DeviceInfo:
                var info = ControlCodec.Payload<DeviceInfo>(envelope);
                if (info is not null) Post(() => Name = info.Name);
                break;

            case ControlType.CameraState:
                var state = ControlCodec.Payload<CameraState>(envelope);
                if (state is null) break;
                // Not posted: the video path reads this per frame and must not
                // wait for the interface thread to get round to it.
                Image.Adjustments = ImageAdjustments.From(state);
                Post(() => State = state);
                break;

            case ControlType.Capabilities:
                var capabilities = ControlCodec.Payload<CameraCapabilities>(envelope);
                if (capabilities is not null) Post(() => Capabilities = capabilities);
                break;

            case ControlType.Telemetry:
                var telemetry = ControlCodec.Payload<TelemetryPayload>(envelope);
                if (telemetry is not null) Post(() => Telemetry = telemetry);
                break;

            case ControlType.StreamStatus:
                var status = ControlCodec.Payload<StreamStatusPayload>(envelope);
                if (status is null) break;
                // Not posted, for the same reason as the camera state above:
                // this arrives on the read loop that also carries the video,
                // so writing it here puts the new geometry in place before the
                // first frame that uses it can possibly be handled.
                _videoFormat = status.Actual;
                Post(() =>
                {
                    StreamProfile = status.Actual;
                    IsStreaming = status.Active;
                });
                break;

            case ControlType.RecordStart:
                // The phone's confirmation, carrying the sessionId it actually
                // opened. The periodic record.state takes over from here.
                var started = ControlCodec.Payload<RecordStartPayload>(envelope);
                if (started is null) break;
                Post(() => Recording = new RecordStatePayload
                {
                    Recording = true,
                    SessionId = started.SessionId,
                    Target = started.Target,
                    ElapsedUs = 0,
                    PhoneOk = true,
                    PcOk = true,
                });
                break;

            case ControlType.RecordState:
                var recordState = ControlCodec.Payload<RecordStatePayload>(envelope);
                if (recordState is null) break;
                Post(() => Recording = recordState.Recording ? recordState : null);
                break;

            case ControlType.RecordStop:
                Post(() => Recording = null);
                break;

            case ControlType.Error:
                var error = ControlCodec.Payload<ProtocolError>(envelope);
                if (error is not null) Log.Net.Warn($"iPhone reported {error.Code}: {error.Message}");
                break;
        }
    }

    private void OnVideo(VideoFrameHeader header, ReadOnlyMemory<byte> body)
    {
        if (header.IsParameterSets)
        {
            // The field, never the property: the property is a step behind
            // whenever the resolution has just changed, and handing the
            // pipeline the previous size would have it build a source that
            // declares the wrong format and then — correctly — rebuild when
            // the truth arrives, resetting the preview in front of the user.
            var format = _videoFormat;
            Video.SetConfiguration(header.Codec, body.Span,
                                   (uint)format.Width, (uint)format.Height);
            return;
        }
        Video.Enqueue(header, body);
    }

    private void Post(Action action)
    {
        if (_dispatcher.HasThreadAccess) action();
        else _dispatcher.TryEnqueue(() => action());
    }

    private void Set<T>(ref T field, T value,
                        [System.Runtime.CompilerServices.CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(name));
    }
}

/// <summary>
/// Every connected iPhone.
///
/// Built for more than one from the start — the collection, the per-device
/// state, and the virtual-camera assignment are all plural — even though Phase
/// 1 only surfaces the first. Retrofitting that later would mean rewriting
/// everything that touches a device.
/// </summary>
public sealed class SessionManager
{
    private readonly DispatcherQueue _dispatcher;

    public ObservableCollection<ConnectedDevice> Devices { get; } = [];

    public event Action<ConnectedDevice>? DeviceAdded;
    public event Action<ConnectedDevice>? DeviceRemoved;
    /// <summary>Raised when a device needs the user to confirm pairing digits.</summary>
    public event Action<ConnectedDevice>? PairingRequested;

    public SessionManager(DispatcherQueue dispatcher) => _dispatcher = dispatcher;

    public bool HasActiveSession => Devices.Count > 0;

    public ConnectedDevice? Primary => Devices.FirstOrDefault();

    public void Add(PeerSession session)
    {
        var device = new ConnectedDevice(session, _dispatcher);

        session.StateChanged += state =>
        {
            _dispatcher.TryEnqueue(() =>
            {
                switch (state)
                {
                    case PeerSession.SessionState.AwaitingTrust:
                        PairingRequested?.Invoke(device);
                        break;
                    case PeerSession.SessionState.Ready when !Devices.Contains(device):
                        Devices.Add(device);
                        DeviceAdded?.Invoke(device);
                        break;
                    case PeerSession.SessionState.Closed:
                        if (Devices.Remove(device))
                        {
                            device.Video.Dispose();
                            DeviceRemoved?.Invoke(device);
                        }
                        break;
                }
            });
        };
    }
}
