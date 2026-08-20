using System.ComponentModel;
using ICam.App.Services;
using ICam.Core.Protocol;
using ICam.Core.Transport;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Navigation;
using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.UI.Xaml;
using Windows.Media.Core;
using Windows.Media.Playback;

namespace ICam.App.Views;

/// <summary>
/// The preview, the two actions that matter, and one inspector.
///
/// Every control here writes through a <see cref="CameraMutation"/> and then
/// waits for the phone to broadcast the state it actually reached. Nothing on
/// this page believes its own value: if the phone clamps an ISO, the slider
/// snaps to what the sensor accepted rather than showing a number that never
/// happened.
/// </summary>
public sealed partial class CameraPage : Page
{
    private AppServices Services => App.Instance.Services;
    private ConnectedDevice? _device;
    private MediaPlayer? _player;

    // The most recent picture, copied off the decoder's thread so drawing never
    // races with the frame that is being produced. Two buffers, swapped under
    // the lock: the producer fills one while the interface thread uploads the
    // other, and neither ever waits for the other's work — only for the swap.
    private readonly Lock _frameLock = new();
    private byte[]? _latestFrame;
    private byte[]? _drawFrame;
    private bool _frameDirty;
    private int _redrawQueued;
    private int _frameWidth;
    private int _frameHeight;
    private CanvasBitmap? _surface;

    /// <summary>
    /// Set while the page is writing values into its own controls, so their
    /// change handlers do not send the state straight back to the phone.
    /// </summary>
    private bool _updatingFromState;

    private readonly DispatcherTimer _recordingTimer = new()
    {
        Interval = TimeSpan.FromSeconds(1),
    };

    public CameraPage()
    {
        InitializeComponent();
        _recordingTimer.Tick += (_, _) => UpdateRecordingReadout();
    }

    protected override void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);

        Services.Sessions.DeviceAdded += OnDeviceAdded;
        Services.Sessions.DeviceRemoved += OnDeviceRemoved;
        Attach(Services.Sessions.Primary);
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);

        Services.Sessions.DeviceAdded -= OnDeviceAdded;
        Services.Sessions.DeviceRemoved -= OnDeviceRemoved;
        Detach();
        _recordingTimer.Stop();
    }

    // MARK: - Device

    private void OnDeviceAdded(ConnectedDevice device)
    {
        if (_device is null) Attach(device);
    }

    private void OnDeviceRemoved(ConnectedDevice device)
    {
        if (_device == device) Detach();
    }

    private void Attach(ConnectedDevice? device)
    {
        Detach();
        _device = device;
        if (device is null)
        {
            ApplyEmptyState();
            return;
        }

        device.PropertyChanged += OnDevicePropertyChanged;
        device.Video.SourceChanged += OnVideoSourceChanged;

        _player = new MediaPlayer
        {
            // A live camera, not a file: never buffer ahead, never loop, and
            // never wait to build a cushion the viewer would experience as lag.
            RealTimePlayback = true,
            AutoPlay = true,
            IsLoopingEnabled = false,
        };
        // A decoder that cannot handle the stream fails here and nowhere
        // else. Without this line that failure is a black rectangle with no
        // explanation anywhere, which is the worst state a camera app can be
        // in — wrong and silent about it.
        _player.MediaFailed += (_, failed) =>
            Log.Media.Error($"Decode failed: {failed.Error} 0x{failed.ExtendedErrorCode?.HResult:X8} " +
                            failed.ErrorMessage);
        // One decode serves the window and iCam Camera both, and the grading
        // happens once, before either sees the frame. So the preview is not an
        // approximation of what is being sent — it is the same buffer.
        Services.Frames.Image = device.Image;
        Services.Frames.FrameReady += OnFrameReady;
        Services.Frames.Attach(_player);

        EmptyState.Visibility = Visibility.Collapsed;
        Inspector.IsEnabled = true;
        PhotoButton.IsEnabled = true;
        RecordButton.IsEnabled = true;
        StreamToggle.IsEnabled = VirtualCameraService.IsSupportedByThisWindows;

        RefreshAll();

        if (Services.Settings.StartStreamingOnConnect)
        {
            _ = device.StartStreamingAsync(ProfileFromSettings());
        }
    }

    private void Detach()
    {
        if (_device is not null)
        {
            _device.PropertyChanged -= OnDevicePropertyChanged;
            _device.Video.SourceChanged -= OnVideoSourceChanged;
        }
        _device = null;

        // Detached before the player is torn down, so nothing is reading a
        // surface as it is disposed. iCam Camera keeps running and falls back
        // to its own card: losing the iPhone must not remove the camera from a
        // call in progress.
        Services.Frames.FrameReady -= OnFrameReady;
        Services.Frames.Attach(null);
        Services.Frames.Image = null;

        if (_player is not null)
        {
            (_player.Source as MediaSource)?.Dispose();
            _player.Dispose();
        }
        _player = null;

        lock (_frameLock)
        {
            _latestFrame = null;
            _drawFrame = null;
            _frameDirty = false;
        }
        Preview.Invalidate();
    }

    // MARK: - Drawing the picture

    /// <summary>
    /// Frames arrive on the decoder's thread. The bytes are copied under a lock
    /// and the canvas is asked to redraw; uploading to the GPU from here would
    /// touch a device the interface thread owns.
    /// </summary>
    private void OnFrameReady(ReadOnlyMemory<byte> nv12, ReadOnlyMemory<byte> display)
    {
        var width = Services.Frames.Width;
        var height = Services.Frames.Height;
        if (width <= 0 || height <= 0) return;

        lock (_frameLock)
        {
            var needed = width * height * 4;
            if (_latestFrame is null || _latestFrame.Length != needed)
            {
                _latestFrame = new byte[needed];
            }
            display.Span[..needed].CopyTo(_latestFrame);
            _frameWidth = width;
            _frameHeight = height;
            _frameDirty = true;
        }

        // One redraw in flight, ever. Asking again while the interface thread
        // is still behind just builds a queue of stale invalidations for it to
        // wade through — which the user experiences as the preview running
        // seconds behind the phone and then lurching to catch up.
        if (Interlocked.Exchange(ref _redrawQueued, 1) == 0)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                Interlocked.Exchange(ref _redrawQueued, 0);
                Preview.Invalidate();
            });
        }
    }

    private void OnPreviewDraw(CanvasControl sender, CanvasDrawEventArgs args)
    {
        int width;
        int height;
        byte[]? pixels;

        // The lock covers a pointer swap and nothing else. The decoder's
        // thread only ever waits the nanoseconds the swap takes — never the
        // milliseconds of a GPU upload, which happen out here on a buffer the
        // producer no longer owns.
        lock (_frameLock)
        {
            if (_latestFrame is null) return;
            width = _frameWidth;
            height = _frameHeight;

            if (_frameDirty)
            {
                (_latestFrame, _drawFrame) = (_drawFrame, _latestFrame);
                _frameDirty = false;
            }
            pixels = _drawFrame;
        }
        if (pixels is null || pixels.Length != width * height * 4) return;

        if (_surface is null || _surface.SizeInPixels.Width != width
            || _surface.SizeInPixels.Height != height)
        {
            _surface?.Dispose();
            _surface = CanvasBitmap.CreateFromBytes(
                sender, pixels, width, height,
                Windows.Graphics.DirectX.DirectXPixelFormat.B8G8R8A8UIntNormalized);
        }
        else
        {
            // Reusing the bitmap rather than allocating one per frame: at
            // thirty frames a second the allocations alone would keep the
            // collector busy for no benefit.
            _surface.SetPixelBytes(pixels);
        }

        // Letterboxed rather than stretched. A face is not worth distorting to
        // fill a rectangle.
        var bounds = sender.Size;
        var scale = Math.Min(bounds.Width / width, bounds.Height / height);
        var drawn = new Windows.Foundation.Rect(
            (bounds.Width - width * scale) / 2,
            (bounds.Height - height * scale) / 2,
            width * scale,
            height * scale);

        args.DrawingSession.DrawImage(_surface, drawn);
    }

    private void ApplyEmptyState()
    {
        EmptyState.Visibility = Visibility.Visible;
        DeviceName.Text = "No iPhone connected";
        DeviceBadge.Visibility = Visibility.Collapsed;
        Inspector.IsEnabled = false;
        PhotoButton.IsEnabled = false;
        RecordButton.IsEnabled = false;
        StreamToggle.IsEnabled = false;
        RecordingChip.Visibility = Visibility.Collapsed;
        _recordingTimer.Stop();
    }

    private void OnVideoSourceChanged(MediaStreamSource source)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (_player is null) return;

            // Re-pointing the player does not release what it was playing, and
            // what it was playing holds a decoder.
            var previous = _player.Source as MediaSource;
            _player.Source = MediaSource.CreateFromMediaStreamSource(source);
            previous?.Dispose();
            _player.Play();
        });
    }

    private void OnDevicePropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            switch (e.PropertyName)
            {
                case nameof(ConnectedDevice.State):
                    ApplyState();
                    break;
                case nameof(ConnectedDevice.Capabilities):
                    ApplyCapabilities();
                    break;
                case nameof(ConnectedDevice.Telemetry):
                    ApplyTelemetry();
                    break;
                case nameof(ConnectedDevice.Name):
                case nameof(ConnectedDevice.StreamProfile):
                case nameof(ConnectedDevice.IsStreaming):
                    ApplyHeader();
                    break;
                case nameof(ConnectedDevice.Recording):
                    ApplyRecording();
                    break;
            }
        });
    }

    private void RefreshAll()
    {
        ApplyCapabilities();
        ApplyState();
        ApplyTelemetry();
        ApplyHeader();
        ApplyRecording();
    }

    /// <summary>
    /// The chip, the button and the timer all follow what the phone said —
    /// never what was clicked here. A recording started on the phone shows up
    /// on this screen, and a click that failed to start one does not.
    /// </summary>
    private void ApplyRecording()
    {
        var recording = _device?.Recording is { Recording: true };

        RecordLabel.Text = recording ? "Stop" : "Record";
        RecordGlyph.Width = RecordGlyph.Height = recording ? 9 : 10;
        RecordingChip.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;

        if (recording)
        {
            UpdateRecordingReadout();
            _recordingTimer.Start();
        }
        else
        {
            _recordingTimer.Stop();
        }
    }

    // MARK: - Rendering state

    private void ApplyHeader()
    {
        if (_device is null) return;

        DeviceName.Text = _device.Name;
        var state = _device.State;
        DeviceSummary.Text = $"{Describe(state.Width, state.Height)} · {state.Fps} · "
                           + (state.Codec == VideoCodec.Hevc ? "HEVC" : "H.264");
        DeviceBadge.Visibility = Visibility.Visible;
        StreamToggle.IsChecked = _device.IsStreaming;
    }

    private void ApplyCapabilities()
    {
        if (_device is null) return;
        var capabilities = _device.Capabilities;
        var state = _device.State;

        _updatingFromState = true;
        try
        {
            LensPicker.Items.Clear();
            foreach (var lens in capabilities.Lenses)
            {
                LensPicker.Items.Add(new ComboBoxItem
                {
                    Content = $"{lens.Label}×  {Describe(lens.Position)}",
                    Tag = lens.Id,
                });
            }
            SelectByTag(LensPicker, state.LensId);

            // The zoom range is the lens's, not a guess: an ultra-wide starts
            // below 1 and a telephoto ends far above 6, and the slider should
            // only offer what the glass can do.
            var currentLens = capabilities.Lenses.FirstOrDefault(l => l.Id == state.LensId);
            if (currentLens is not null && currentLens.MaxZoom > currentLens.MinZoom)
            {
                ZoomSlider.Minimum = Math.Max(currentLens.MinZoom, 0.5);
                ZoomSlider.Maximum = Math.Min(currentLens.MaxZoom, 15);
            }

            ResolutionPicker.Items.Clear();
            foreach (var (width, height) in capabilities.ResolutionsFor(state.LensId))
            {
                ResolutionPicker.Items.Add(new ComboBoxItem
                {
                    Content = Describe(width, height),
                    Tag = $"{width}x{height}",
                });
            }
            SelectByTag(ResolutionPicker, $"{state.Width}x{state.Height}");

            FrameRatePicker.Items.Clear();
            foreach (var rate in capabilities.FrameRatesFor(state.LensId, state.Width, state.Height))
            {
                FrameRatePicker.Items.Add(new ComboBoxItem
                {
                    Content = $"{rate} fps",
                    Tag = rate.ToString(),
                });
            }
            SelectByTag(FrameRatePicker, state.Fps.ToString());

            // Ranges come from the live device, so the slider cannot reach a
            // value this sensor does not have.
            var format = capabilities.FormatsFor(state.LensId)
                .FirstOrDefault(f => f.Width == state.Width && f.Height == state.Height);
            if (format is { IsoRange.Count: 2 } && format.IsoRange[1] > format.IsoRange[0])
            {
                IsoSlider.Minimum = format.IsoRange[0];
                IsoSlider.Maximum = format.IsoRange[1];
            }
            if (format is { ExposureDurationUsRange.Count: 2 }
                && format.ExposureDurationUsRange[1] > format.ExposureDurationUsRange[0])
            {
                ShutterSlider.Minimum = format.ExposureDurationUsRange[0];
                // A quarter second is the slowest shutter worth offering for
                // handheld video; beyond it the slider is only harder to aim.
                ShutterSlider.Maximum = Math.Min(format.ExposureDurationUsRange[1], 250_000);
            }

            TorchToggle.IsEnabled = capabilities.Torch.Supported;
            ManualWhiteBalancePanel.Visibility = capabilities.WhiteBalance.Supported
                ? Visibility.Visible : Visibility.Collapsed;
        }
        finally
        {
            _updatingFromState = false;
        }
    }

    private void ApplyState()
    {
        if (_device is null) return;
        var state = _device.State;

        _updatingFromState = true;
        try
        {
            SelectByTag(LensPicker, state.LensId);
            SelectByTag(ResolutionPicker, $"{state.Width}x{state.Height}");
            SelectByTag(FrameRatePicker, state.Fps.ToString());
            SelectByTag(ExposureModePicker, state.ExposureMode == ExposureMode.Manual
                ? "manual" : "auto");
            SelectByTag(WhiteBalanceModePicker, state.WhiteBalanceMode == WhiteBalanceMode.Manual
                ? "manual" : "auto");
            SelectByTag(FocusModePicker, state.FocusMode switch
            {
                FocusMode.Manual => "manual",
                FocusMode.Single => "single",
                _ => "continuous",
            });

            var manualExposure = state.ExposureMode == ExposureMode.Manual;
            ManualExposurePanel.Visibility = manualExposure
                ? Visibility.Visible : Visibility.Collapsed;
            AutoExposurePanel.Visibility = manualExposure
                ? Visibility.Collapsed : Visibility.Visible;

            EvSlider.Value = state.Ev;
            EvReadout.Text = $"{state.Ev:+0.0;-0.0;0.0} EV";

            IsoSlider.Value = Math.Clamp(state.Iso, IsoSlider.Minimum, IsoSlider.Maximum);
            IsoReadout.Text = $"{state.Iso:0}";

            ShutterSlider.Value = Math.Clamp(state.ExposureDurationUs,
                                             ShutterSlider.Minimum, ShutterSlider.Maximum);
            ShutterReadout.Text = $"1/{state.ShutterDenominator}";

            ManualWhiteBalancePanel.Visibility =
                state.WhiteBalanceMode == WhiteBalanceMode.Manual
                    ? Visibility.Visible : Visibility.Collapsed;
            TemperatureSlider.Value = Math.Clamp(state.Temperature, 2000, 10000);
            TemperatureReadout.Text = $"{state.Temperature:0} K";

            TorchToggle.IsOn = state.Torch != TorchMode.Off;
            MirrorToggle.IsOn = state.Mirrored;

            ZoomSlider.Value = Math.Clamp(state.Zoom, ZoomSlider.Minimum, ZoomSlider.Maximum);
            ZoomReadout.Text = $"{state.Zoom:0.0}×";

            BrightnessSlider.Value = state.Brightness;
            ContrastSlider.Value = state.Contrast;
            SaturationSlider.Value = state.Saturation;
            WarmthSlider.Value = state.Warmth;
            SharpnessSlider.Value = state.Sharpness;
            LowLightSlider.Value = state.LowLight;
            BeautySlider.Value = state.Beauty;

            BrightnessReadout.Text = Describe(state.Brightness);
            ContrastReadout.Text = Describe(state.Contrast);
            SaturationReadout.Text = Describe(state.Saturation);
            WarmthReadout.Text = Describe(state.Warmth);
            SharpnessReadout.Text = Describe(state.Sharpness);
            LowLightReadout.Text = DescribePercent(state.LowLight);
            BeautyReadout.Text = DescribePercent(state.Beauty);
        }
        finally
        {
            _updatingFromState = false;
        }

        ApplyHeader();
    }

    private void ApplyTelemetry()
    {
        if (_device?.Telemetry is not { } telemetry)
        {
            BatteryReadout.Text = "—";
            ThermalReadout.Text = "—";
            StorageReadout.Text = "—";
            return;
        }

        BatteryReadout.Text = $"{(int)(telemetry.Battery * 100)}%  {Describe(telemetry.Power)}";
        ThermalReadout.Text = telemetry.Thermal switch
        {
            "elevated" => "Elevated",
            "high" => "High",
            "critical" => "High",
            _ => "Normal",
        };
        StorageReadout.Text = DescribeBytes(telemetry.StorageFreeBytes);
    }

    private void UpdateRecordingReadout()
    {
        if (_device is null) return;
        var seconds = (long)(_device.RecordingElapsedUs / 1_000_000);
        RecordingElapsed.Text = seconds >= 3600
            ? $"{seconds / 3600}:{seconds / 60 % 60:D2}:{seconds % 60:D2}"
            : $"{seconds / 60:D2}:{seconds % 60:D2}";
    }

    // MARK: - Actions

    private async void OnTakePhoto(object sender, RoutedEventArgs e)
    {
        if (_device is null) return;
        await _device.Session.SendControlAsync(ControlType.PhotoCapture,
            new PhotoCapturePayload { Target = CaptureTarget.Both, RequestId = 1 });
    }

    private async void OnToggleRecording(object sender, RoutedEventArgs e)
    {
        if (_device is null) return;

        // Only the request goes out from here. The chip, the label and the
        // timer wait for the phone's answer, because the phone is the machine
        // with the storage, the sensor and the right to say no.
        if (_device.Recording is { Recording: true } current)
        {
            await _device.Session.SendControlAsync(ControlType.RecordStop,
                new RecordStopPayload { SessionId = current.SessionId ?? "" });
        }
        else
        {
            await _device.Session.SendControlAsync(ControlType.RecordStart,
                new RecordStartPayload
                {
                    Target = CaptureTarget.Both,
                    SessionId = DateTimeOffset.Now.ToString("yyyyMMdd-HHmmss"),
                    StartedAtUs = MonotonicClock.NowUs(),
                });
        }
    }

    private async void OnToggleStreaming(object sender, RoutedEventArgs e)
    {
        if (_device is null) return;
        if (StreamToggle.IsChecked == true)
        {
            await _device.StartStreamingAsync(ProfileFromSettings());
        }
        else
        {
            await _device.StopStreamingAsync();
        }
    }

    private void OnConnectHelpClick(object sender, RoutedEventArgs e) =>
        Frame.Navigate(typeof(DevicesPage));

    // MARK: - Control handlers

    private void OnLensChanged(object sender, SelectionChangedEventArgs e) =>
        Send(m => m.LensId = TagOf(LensPicker));

    private void OnResolutionChanged(object sender, SelectionChangedEventArgs e)
    {
        var tag = TagOf(ResolutionPicker);
        if (tag is null) return;
        var parts = tag.Split('x');
        if (parts.Length != 2 || !int.TryParse(parts[0], out var width)
            || !int.TryParse(parts[1], out var height)) return;

        Send(m => { m.Width = width; m.Height = height; });
    }

    private void OnFrameRateChanged(object sender, SelectionChangedEventArgs e)
    {
        if (int.TryParse(TagOf(FrameRatePicker), out var fps)) Send(m => m.Fps = fps);
    }

    private void OnExposureModeChanged(object sender, SelectionChangedEventArgs e) =>
        Send(m => m.ExposureMode = TagOf(ExposureModePicker) == "manual"
            ? ExposureMode.Manual : ExposureMode.Auto);

    private void OnWhiteBalanceModeChanged(object sender, SelectionChangedEventArgs e) =>
        Send(m => m.WhiteBalanceMode = TagOf(WhiteBalanceModePicker) == "manual"
            ? WhiteBalanceMode.Manual : WhiteBalanceMode.Auto);

    private void OnFocusModeChanged(object sender, SelectionChangedEventArgs e) =>
        Send(m => m.FocusMode = TagOf(FocusModePicker) switch
        {
            "manual" => FocusMode.Manual,
            "single" => FocusMode.Single,
            _ => FocusMode.Continuous,
        });

    private void OnEvChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        EvReadout.Text = $"{e.NewValue:+0.0;-0.0;0.0} EV";
        Send(m => m.Ev = Math.Round(e.NewValue, 1));
    }

    private void OnIsoChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        IsoReadout.Text = $"{e.NewValue:0}";
        Send(m => m.Iso = Math.Round(e.NewValue));
    }

    private void OnShutterChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        var denominator = (int)Math.Round(1_000_000 / Math.Max(e.NewValue, 1));
        ShutterReadout.Text = $"1/{denominator}";
        Send(m => m.ExposureDurationUs = (int)e.NewValue);
    }

    private void OnTemperatureChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        TemperatureReadout.Text = $"{e.NewValue:0} K";
        Send(m =>
        {
            m.Temperature = Math.Round(e.NewValue);
            m.WhiteBalancePreset = WhiteBalancePreset.Custom;
        });
    }

    private void OnTorchToggled(object sender, RoutedEventArgs e) =>
        Send(m => m.Torch = TorchToggle.IsOn ? TorchMode.On : TorchMode.Off);

    private void OnMirrorToggled(object sender, RoutedEventArgs e) =>
        Send(m => m.Mirrored = MirrorToggle.IsOn);

    private void OnZoomChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        ZoomReadout.Text = $"{e.NewValue:0.0}×";
        Send(m => m.Zoom = Math.Round(e.NewValue, 1));
    }

    private void OnBrightnessChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        BrightnessReadout.Text = Describe(e.NewValue);
        Send(m => m.Brightness = Math.Round(e.NewValue, 2));
    }

    private void OnContrastChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        ContrastReadout.Text = Describe(e.NewValue);
        Send(m => m.Contrast = Math.Round(e.NewValue, 2));
    }

    private void OnSaturationChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        SaturationReadout.Text = Describe(e.NewValue);
        Send(m => m.Saturation = Math.Round(e.NewValue, 2));
    }

    private void OnWarmthChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        WarmthReadout.Text = Describe(e.NewValue);
        Send(m => m.Warmth = Math.Round(e.NewValue, 2));
    }

    private void OnSharpnessChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        SharpnessReadout.Text = Describe(e.NewValue);
        Send(m => m.Sharpness = Math.Round(e.NewValue, 2));
    }

    private void OnLowLightChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        LowLightReadout.Text = DescribePercent(e.NewValue);
        Send(m => m.LowLight = Math.Round(e.NewValue, 2));
    }

    private void OnBeautyChanged(object sender, RangeBaseValueChangedEventArgs e)
    {
        BeautyReadout.Text = DescribePercent(e.NewValue);
        Send(m => m.Beauty = Math.Round(e.NewValue, 2));
    }

    private static string DescribePercent(double value) => $"{value * 100:0}%";

    /// <summary>
    /// All of them in one mutation, so they come back together as a single
    /// state rather than as seven the phone has to reconcile in turn.
    /// </summary>
    private void OnResetImage(object sender, RoutedEventArgs e) =>
        Send(m =>
        {
            m.Brightness = 0;
            m.Contrast = 0;
            m.Saturation = 0;
            m.Warmth = 0;
            m.Sharpness = 0;
            m.LowLight = 0;
            m.Beauty = 0;
        });

    /// <summary>
    /// Sends one mutation carrying only what this control touched. That is what
    /// lets the phone and this window be edited at the same time without either
    /// reverting the other; see <c>docs/PROTOCOL.md</c> section 5.4.
    /// </summary>
    private void Send(Action<CameraMutation> build)
    {
        if (_updatingFromState || _device is null) return;
        var mutation = new CameraMutation();
        build(mutation);
        _ = _device.ApplyAsync(mutation);
    }

    // MARK: - Helpers

    private StreamProfile ProfileFromSettings() => Services.Settings.StreamProfileName switch
    {
        "720p30" => StreamProfile.Webcam720p30,
        "1080p60" => StreamProfile.Webcam1080p60,
        _ => StreamProfile.Webcam1080p30,
    };

    private static string? TagOf(ComboBox box) =>
        (box.SelectedItem as ComboBoxItem)?.Tag as string;

    private static void SelectByTag(ComboBox box, string tag)
    {
        for (var i = 0; i < box.Items.Count; i++)
        {
            if (box.Items[i] is ComboBoxItem item && (item.Tag as string) == tag)
            {
                box.SelectedIndex = i;
                return;
            }
        }
        if (box.SelectedIndex < 0 && box.Items.Count > 0) box.SelectedIndex = 0;
    }

    private static string Describe(int width, int height) => (width, height) switch
    {
        (3840, 2160) or (4096, 2160) => "4K",
        (2560, 1440) => "1440p",
        (1920, 1080) => "1080p",
        (1280, 720) => "720p",
        _ => $"{width} × {height}",
    };

    /// <summary>An image control, which is always signed and always centred on 0.</summary>
    private static string Describe(double amount) => $"{amount:+0.00;-0.00;0.00}";

    private static string Describe(string value) => value switch
    {
        "front" => "Front",
        "back" => "Back",
        "usb" => "USB",
        "wireless" => "Wireless",
        "battery" => "Battery",
        _ => value,
    };

    private static string DescribeBytes(ulong bytes)
    {
        const double gigabyte = 1024d * 1024 * 1024;
        return bytes >= gigabyte
            ? $"{bytes / gigabyte:0.#} GB free"
            : $"{bytes / (1024d * 1024):0} MB free";
    }
}
