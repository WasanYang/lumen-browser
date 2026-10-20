using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace MiniBrowser;

public partial class MainWindow : Window
{
    const string HomeUrl = "https://www.youtube.com";
    const string SearchUrl = "https://www.google.com/search?q=";
    static readonly TimeSpan SleepAfter = TimeSpan.FromMinutes(5);
    static readonly Brush ActiveTabBrush = new SolidColorBrush(Color.FromRgb(0x3A, 0x3A, 0x3A));

    sealed class Tab
    {
        public required WebView2 View;
        public required Button Header;
        public required TextBlock Label;
        public DateTime LastActive = DateTime.Now;
    }

    readonly List<Tab> _tabs = [];
    readonly DispatcherTimer _sleepTimer = new() { Interval = TimeSpan.FromMinutes(1) };
    Tab? _current;
    CoreWebView2Environment _env = null!;
    string _dataDir = "";
    Task? _extensionsInstalled;
    AdBlock _adBlock = null!;
    bool _fullScreen;
    WindowState _stateBeforeFullScreen;

    public MainWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) => UseDarkTitleBar();
        Loaded += async (_, _) =>
        {
            _dataDir = Environment.GetEnvironmentVariable("MINIBROWSER_DATA") ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MiniBrowser");
            _env = await CoreWebView2Environment.CreateAsync(null, _dataDir,
                new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = true });
            _adBlock = AdBlock.Load(Path.Combine(AppContext.BaseDirectory, "blocklist.txt"));
            await NewTab(Environment.GetCommandLineArgs().Skip(1).FirstOrDefault() ?? HomeUrl);
        };
        _sleepTimer.Tick += (_, _) => SleepIdleTabs();
        _sleepTimer.Start();
    }

    async Task NewTab(string? url)
    {
        var label = new TextBlock { Text = "แท็บใหม่", TextTrimming = TextTrimming.CharacterEllipsis };
        var header = new Button { Style = (Style)FindResource("TabButton"), Content = label };
        var view = new WebView2 { Visibility = Visibility.Collapsed, DefaultBackgroundColor = System.Drawing.Color.FromArgb(0x1E, 0x1E, 0x1E) };
        var tab = new Tab { View = view, Header = header, Label = label };

        header.Click += (_, _) => Activate(tab);
        header.PreviewMouseDown += (_, e) => { if (e.ChangedButton == MouseButton.Middle) CloseTab(tab); };
        _tabs.Add(tab);
        TabStrip.Children.Add(header);
        Pages.Children.Add(view);
        Activate(tab);

        await view.EnsureCoreWebView2Async(_env);
        var core = view.CoreWebView2;
        core.Settings.IsStatusBarEnabled = false;
        // Extensions live in the shared profile, so install them once, before the first page loads.
        _extensionsInstalled ??= Extensions.InstallAsync(core.Profile, _dataDir);
        try { await _extensionsInstalled; }
        catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"Extension install failed: {ex}"); }
        RefreshUBlockTooltip();
        await _adBlock.AttachAsync(core, _env);

        core.DocumentTitleChanged += (_, _) =>
        {
            label.Text = core.DocumentTitle;
            header.ToolTip = core.DocumentTitle;
            if (tab == _current) Title = core.DocumentTitle;
        };
        core.SourceChanged += (_, _) =>
        {
            if (tab == _current && !UrlBox.IsKeyboardFocusWithin) UrlBox.Text = core.Source;
        };
        // Pop-ups that the user did not click on (typical ad pop-unders) are dropped.
        core.NewWindowRequested += (_, e) =>
        {
            e.Handled = true;
            if (e.IsUserInitiated) _ = NewTab(e.Uri);
        };
        core.ContainsFullScreenElementChanged += (_, _) => SetFullScreen(core.ContainsFullScreenElement);

        if (url is null) { UrlBox.Focus(); return; }
        core.Navigate(url);
    }

    void Activate(Tab tab)
    {
        if (_current is { } prev && prev != tab)
        {
            prev.View.Visibility = Visibility.Collapsed;
            prev.Header.Background = Brushes.Transparent;
            prev.LastActive = DateTime.Now;
            if (prev.View.CoreWebView2 is { IsDocumentPlayingAudio: false } prevCore)
                prevCore.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Low;
        }
        _current = tab;
        tab.View.Visibility = Visibility.Visible;
        tab.Header.Background = ActiveTabBrush;
        tab.LastActive = DateTime.Now;
        if (tab.View.CoreWebView2 is { } core)
        {
            core.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Normal;
            Title = core.DocumentTitle;
        }
        UrlBox.Text = tab.View.Source?.ToString() ?? "";
        tab.Header.BringIntoView();
        tab.View.Focus();
    }

    void CloseTab(Tab tab)
    {
        var index = _tabs.IndexOf(tab);
        _tabs.RemoveAt(index);
        TabStrip.Children.Remove(tab.Header);
        Pages.Children.Remove(tab.View);
        tab.View.Dispose();
        if (_tabs.Count == 0) { Close(); return; }
        if (tab == _current)
        {
            _current = null;
            Activate(_tabs[Math.Min(index, _tabs.Count - 1)]);
        }
    }

    void SwitchTab(int step)
    {
        if (_current is null || _tabs.Count < 2) return;
        var i = (_tabs.IndexOf(_current) + step + _tabs.Count) % _tabs.Count;
        Activate(_tabs[i]);
    }

    // Background tabs idle for a while are frozen (no CPU); ones playing audio are left alone.
    async void SleepIdleTabs()
    {
        foreach (var tab in _tabs.ToList())
        {
            if (tab == _current || tab.View.CoreWebView2 is not { } core) continue;
            if (core.IsSuspended || core.IsDocumentPlayingAudio) continue;
            if (DateTime.Now - tab.LastActive < SleepAfter) continue;
            try { await core.TrySuspendAsync(); } catch (InvalidOperationException) { }
        }
    }

    void SetFullScreen(bool on)
    {
        if (on == _fullScreen) return;
        _fullScreen = on;
        TopBar.Visibility = on ? Visibility.Collapsed : Visibility.Visible;
        if (on)
        {
            _stateBeforeFullScreen = WindowState;
            WindowStyle = WindowStyle.None;
            WindowState = WindowState.Normal; // re-maximize so the taskbar is covered
            WindowState = WindowState.Maximized;
        }
        else
        {
            WindowStyle = WindowStyle.SingleBorderWindow;
            WindowState = _stateBeforeFullScreen;
        }
    }

    static string ToUrl(string text)
    {
        text = text.Trim();
        if (text.StartsWith("localhost") || text.StartsWith("127.0.0.1")) return "http://" + text;
        if (Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "file" or "about")
            return uri.ToString();
        if (!text.Contains(' ') && text.Contains('.')) return "https://" + text;
        return SearchUrl + Uri.EscapeDataString(text);
    }

    void Window_PreviewKeyDown(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);

        if (ctrl && e.Key == Key.L) UrlBox.Focus();
        else if (ctrl && e.Key == Key.T) _ = NewTab(null);
        else if (ctrl && e.Key == Key.W) { if (_current is not null) CloseTab(_current); }
        else if (ctrl && e.Key == Key.Tab) SwitchTab(shift ? -1 : 1);
        else if (ctrl && e.Key == Key.D9) Activate(_tabs[^1]);
        else if (ctrl && e.Key is >= Key.D1 and <= Key.D8 && e.Key - Key.D1 < _tabs.Count) Activate(_tabs[e.Key - Key.D1]);
        else if (e.Key == Key.F11) SetFullScreen(!_fullScreen);
        else return;
        e.Handled = true;
    }

    void NewTab_Click(object sender, RoutedEventArgs e) => _ = NewTab(null);

    async void UpdateUBlock_Click(object sender, RoutedEventArgs e)
    {
        if (_dataDir.Length == 0) return;
        UBlockButton.IsEnabled = false;
        UBlockButton.Content = "กำลังตรวจสอบ…";
        try
        {
            var message = await Extensions.DownloadUBlockUpdateAsync(_dataDir);
            MessageBox.Show(this, message, "uBlock Origin Lite");
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"อัปเดตไม่สำเร็จ: {ex.Message}", "uBlock Origin Lite",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            UBlockButton.Content = "↻ uBO";
            UBlockButton.IsEnabled = true;
            RefreshUBlockTooltip();
        }
    }

    void RefreshUBlockTooltip()
    {
        var version = Extensions.InstalledVersion(_dataDir, Extensions.UBlockKey);
        var pending = Extensions.PendingVersion(_dataDir, Extensions.UBlockKey);
        UBlockButton.ToolTip = $"อัปเดต uBlock Origin Lite (ตอนนี้ใช้รุ่น {version?.ToString() ?? "-"})" +
            (pending is null ? "" : $"\nรุ่น {pending} จะเริ่มใช้เมื่อเปิดโปรแกรมใหม่");
    }

    void UrlBox_GotKeyboardFocus(object sender, KeyboardFocusChangedEventArgs e) =>
        Dispatcher.BeginInvoke(UrlBox.SelectAll);

    void UrlBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (_current is null) return;
        if (e.Key == Key.Enter && !string.IsNullOrWhiteSpace(UrlBox.Text))
        {
            _current.View.CoreWebView2?.Navigate(ToUrl(UrlBox.Text));
            _current.View.Focus();
        }
        else if (e.Key == Key.Escape)
        {
            UrlBox.Text = _current.View.Source?.ToString() ?? "";
            _current.View.Focus();
        }
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    void UseDarkTitleBar()
    {
        const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        var on = 1;
        DwmSetWindowAttribute(new WindowInteropHelper(this).Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int));
    }
}
