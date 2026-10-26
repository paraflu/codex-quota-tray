using Microsoft.Win32;
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class NativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool DestroyIcon(IntPtr handle);
}


internal sealed class QuotaWindow
{
    public string Key, Label; public int Minutes; public double Used; public double Remaining; public long? ResetsAt;
}

internal sealed class Snapshot
{
    public List<QuotaWindow> Windows = new List<QuotaWindow>();
    public string Plan, Reached, Source, Error; public DateTime Observed;
}

internal sealed class TrayApp : ApplicationContext
{
    private const string StartupValue = "CodexQuotaTray";
    private readonly NotifyIcon tray = new NotifyIcon();
    private readonly Timer timer = new Timer { Interval = 15000 };
    private readonly Timer postResetTimer = new Timer { Interval = 5000 };
    private readonly Font menuFont = new Font("Segoe UI", 9);
    private readonly Font titleFont = new Font("Segoe UI Semibold", 10);
    private Icon currentIcon;
    private long? displayedResetAt;
    private bool postResetRefreshQueued;

    public TrayApp()
    {
        timer.Tick += delegate { if (tray.ContextMenuStrip == null || !tray.ContextMenuStrip.Visible) Refresh(); };
        postResetTimer.Tick += delegate { postResetTimer.Stop(); if (tray.ContextMenuStrip == null || !tray.ContextMenuStrip.Visible) Refresh(); };
        // Windows registers a NotifyIcon more reliably when it has an icon before
        // it is made visible.  Register a known-good fallback first; Refresh()
        // immediately replaces it with the quota indicator.
        tray.Icon = SystemIcons.Application;
        tray.Text = "Codex Quota Tray";
        tray.Visible = true;
        tray.MouseClick += delegate(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left) tray.ContextMenuStrip.Show(Cursor.Position);
        };
        Refresh();
        timer.Start();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            timer.Dispose(); postResetTimer.Dispose();
            var menu = tray.ContextMenuStrip;
            tray.Dispose();
            if (menu != null) menu.Dispose();
            if (currentIcon != null) currentIcon.Dispose();
            titleFont.Dispose(); menuFont.Dispose();
        }
        base.Dispose(disposing);
    }
    private static string Label(int minutes)
    {
        if (minutes == 300) return "5-hour usage";
        if (minutes == 1440) return "1-day usage";
        if (minutes == 10080) return "7-day usage";
        if (minutes % 1440 == 0) return (minutes / 1440) + "-day usage";
        if (minutes % 60 == 0) return (minutes / 60) + "-hour usage";
        return minutes + "-minute usage";
    }

    private static string Relative(long? unix)
    {
        if (!unix.HasValue) return "--";
        var seconds = (long)(DateTimeOffset.FromUnixTimeSeconds(unix.Value).LocalDateTime - DateTime.Now).TotalSeconds;
        if (seconds <= 0) return "now";
        var days = seconds / 86400; var hours = (seconds % 86400) / 3600; var minutes = (seconds % 3600) / 60;
        if (days > 0) return days + "d" + hours + "h";
        if (hours > 0) return hours + "h" + minutes + "m";
        return Math.Max(1, minutes) + "m";
    }


    private static object Get(Dictionary<string, object> value, string key)
    {
        object result; return value != null && value.TryGetValue(key, out result) ? result : null;
    }

    private static double? Number(object value)
    {
        double result; return value != null && double.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Any, CultureInfo.InvariantCulture, out result) ? (double?)result : null;
    }

    private static Snapshot Load()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var files = new List<FileInfo>();
        foreach (var root in new[] { Path.Combine(home, ".codex", "sessions"), Path.Combine(home, ".codex", "archived_sessions") })
            if (Directory.Exists(root)) files.AddRange(Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories).Select(x => new FileInfo(x)));
        if (files.Count == 0) return new Snapshot { Error = "No Codex session logs found." };

        Snapshot best = null; var serializer = new JavaScriptSerializer();
        foreach (var file in files.OrderByDescending(x => x.LastWriteTime).Take(120))
        {
            string text;
            try
            {
                using (var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    stream.Seek(Math.Max(0, stream.Length - 1048576), SeekOrigin.Begin);
                    using (var reader = new StreamReader(stream)) text = reader.ReadToEnd();
                }
            }
            catch { continue; }
            foreach (var line in text.Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries).Reverse())
            {
                if (!line.Contains("\"token_count\"") || !line.Contains("\"rate_limits\"")) continue;
                try
                {
                    var record = serializer.Deserialize<Dictionary<string, object>>(line);
                    var payload = Get(record, "payload") as Dictionary<string, object>;
                    if (payload == null || Convert.ToString(Get(payload, "type")) != "token_count") continue;
                    var limits = Get(payload, "rate_limits") as Dictionary<string, object>;
                    if (limits == null) continue;
                    var snapshot = new Snapshot { Source = file.FullName, Plan = Convert.ToString(Get(limits, "plan_type")), Reached = Convert.ToString(Get(limits, "rate_limit_reached_type")) };
                    DateTime observed; snapshot.Observed = DateTime.TryParse(Convert.ToString(Get(record, "timestamp")), null, DateTimeStyles.RoundtripKind, out observed) ? observed.ToLocalTime() : DateTime.MinValue;
                    foreach (var pair in limits)
                    {
                        var data = pair.Value as Dictionary<string, object>; if (data == null) continue;
                        var used = Number(Get(data, "used_percent")); var minutes = Number(Get(data, "window_minutes"));
                        if (!used.HasValue || !minutes.HasValue || minutes.Value <= 0) continue;
                        var reset = Number(Get(data, "resets_at"));
                        snapshot.Windows.Add(new QuotaWindow { Key = pair.Key, Minutes = (int)minutes.Value, Label = Label((int)minutes.Value), Used = used.Value, Remaining = Math.Max(0, Math.Min(100, 100 - used.Value)), ResetsAt = reset.HasValue ? (long?)reset.Value : null });
                    }
                    snapshot.Windows = snapshot.Windows.OrderBy(x => x.Minutes).ThenBy(x => x.Key).ToList();
                    if (snapshot.Windows.Count > 0 || !String.IsNullOrEmpty(snapshot.Reached))
                    {
                        if (best == null || snapshot.Observed > best.Observed) best = snapshot;
                        break;
                    }
                }
                catch { }
            }
        }
        return best ?? new Snapshot { Error = "No rate limit event found in recent Codex logs." };
    }

    internal static Color QuotaColor(double remaining)
    {
        return ColorTranslator.FromHtml(remaining >= 40 ? "#30A46C" : remaining >= 20 ? "#B7791F" : "#D64550");
    }

    internal static Icon DrawIcon(Snapshot snapshot)
    {
        using (var bitmap = new Bitmap(32, 32))
        {
            using (var g = Graphics.FromImage(bitmap))
            {
                g.Clear(Color.Transparent); g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                using (var pen = new Pen(Color.Gray, 2))
                {
                    g.DrawLines(pen, new[] { new Point(2, 11), new Point(6, 15), new Point(2, 19) });
                    g.DrawLine(pen, 6, 21, 10, 21);
                }
                var shown = snapshot.Windows.Take(2).ToList();
                if (shown.Count == 0)
                {
                    g.FillEllipse(Brushes.Gray, 17, 14, 3, 3);
                    g.FillEllipse(Brushes.Gray, 25, 14, 3, 3);
                }
                for (var i = 0; i < shown.Count; i++)
                {
                    var y = shown.Count == 1 ? 16 : 10 + 12 * i;
                    var remaining = Math.Max(0, Math.Min(100, shown[i].Remaining));
                    using (var pen = new Pen(Color.FromArgb(100, 128, 128, 128), 6))
                    {
                        pen.StartCap = pen.EndCap = System.Drawing.Drawing2D.LineCap.Round;
                        g.DrawLine(pen, 16, y, 28, y);
                        if (remaining > 0)
                        {
                            pen.Color = QuotaColor(remaining);
                            g.DrawLine(pen, 16, y, (float)(16 + 12 * remaining / 100), y);
                        }
                    }
                }
            }
            var handle = bitmap.GetHicon();
            try { using (var borrowed = Icon.FromHandle(handle)) return (Icon)borrowed.Clone(); }
            finally { NativeMethods.DestroyIcon(handle); }
        }
    }

    internal static ToolStripControlHost NewQuotaCard(QuotaWindow window, Font titleFont)
    {
        var panel = new Panel { Size = new Size(296, 88), BackColor = ColorTranslator.FromHtml("#F7F8FA") };
        panel.Controls.Add(new Label { Text = window.Label, Bounds = new Rectangle(12, 10, 164, 22),
            Font = titleFont, ForeColor = ColorTranslator.FromHtml("#20242C") });
        panel.Controls.Add(new Label { Text = Math.Round(window.Remaining) + "% left", Bounds = new Rectangle(178, 10, 106, 22),
            TextAlign = ContentAlignment.TopRight, Font = titleFont, ForeColor = QuotaColor(window.Remaining) });
        panel.Controls.Add(new Label { Text = Math.Round(window.Used) + "% used  /  Resets in " + Relative(window.ResetsAt),
            Bounds = new Rectangle(12, 59, 272, 22), ForeColor = ColorTranslator.FromHtml("#626B78") });
        panel.Paint += delegate(object sender, PaintEventArgs e)
        {
            e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using (var pen = new Pen(ColorTranslator.FromHtml("#E2E5EA"), 8))
            {
                pen.StartCap = pen.EndCap = System.Drawing.Drawing2D.LineCap.Round;
                e.Graphics.DrawLine(pen, 16, 43, 280, 43);
                var remaining = Math.Max(0, Math.Min(100, window.Remaining));
                if (remaining > 0)
                {
                    pen.Color = QuotaColor(remaining);
                    e.Graphics.DrawLine(pen, 16, 43, (float)(16 + 264 * remaining / 100), 43);
                }
            }
        };
        return new ToolStripControlHost(panel) { Margin = new Padding(8, 4, 8, 4) };
    }

    private void Refresh()
    {
        var snapshot = Load();
        var menu = new ContextMenuStrip { Font = menuFont, BackColor = Color.White,
            ForeColor = ColorTranslator.FromHtml("#20242C"), RenderMode = ToolStripRenderMode.System,
            ShowImageMargin = false, ShowCheckMargin = true, Padding = new Padding(4, 6, 4, 6), ShowItemToolTips = true };
        QueuePostResetRefresh(snapshot);
        menu.Items.Add(new ToolStripLabel("Codex Quota") { Font = titleFont, Margin = new Padding(12, 6, 12, 4) });
        if (!String.IsNullOrEmpty(snapshot.Error)) { AddDisabled(menu, snapshot.Error); tray.Text = "Codex quota: unavailable"; }
        else
        {
            if (!String.IsNullOrEmpty(snapshot.Plan)) AddDisabled(menu, "Plan: " + snapshot.Plan);
            if (!String.IsNullOrEmpty(snapshot.Reached)) menu.Items.Add(new ToolStripLabel("Limit reached: " + snapshot.Reached) { ForeColor = QuotaColor(0) });
            var tooltip = new List<string>();
            foreach (var window in snapshot.Windows)
            {
                menu.Items.Add(NewQuotaCard(window, titleFont));
                tooltip.Add(window.Label + " " + Math.Round(window.Remaining) + "% left");
            }
            AddDisabled(menu, "Updated " + snapshot.Observed.ToString("g"));
            menu.Items[menu.Items.Count - 1].ToolTipText = "Source: " + snapshot.Source;
            tray.Text = String.Join(" / ", tooltip).Substring(0, Math.Min(63, String.Join(" / ", tooltip).Length));
        }
        menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("Refresh now", null, delegate { Refresh(); });
        menu.Items.Add("Open session logs", null, delegate { System.Diagnostics.Process.Start(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions")); });
        var login = (ToolStripMenuItem)menu.Items.Add("Start at login", null, delegate { SetStartup(!IsStartup()); Refresh(); }); login.Checked = IsStartup();
        menu.Items.Add(new ToolStripSeparator()); menu.Items.Add("Quit", null, delegate { tray.Visible = false; ExitThread(); });
        var previousMenu = tray.ContextMenuStrip;
        tray.ContextMenuStrip = menu;
        if (previousMenu != null) previousMenu.Dispose();
        var next = DrawIcon(snapshot); tray.Icon = next; if (currentIcon != null) currentIcon.Dispose(); currentIcon = next;
    }

    // A reset is reflected only when Codex writes a new local rate-limit record.
    // The current scan is the first refresh; schedule one more scan five seconds later.
    private void QueuePostResetRefresh(Snapshot snapshot)
    {
        var shown = snapshot.Windows.Take(2).ToList();
        long? resetAt = shown.Count > 1 ? shown[1].ResetsAt : shown.Count == 1 ? shown[0].ResetsAt : null;
        if (!resetAt.HasValue) return;
        if (displayedResetAt != resetAt)
        {
            displayedResetAt = resetAt;
            postResetRefreshQueued = false;
        }
        if (!postResetRefreshQueued && DateTimeOffset.UtcNow.ToUnixTimeSeconds() >= resetAt.Value)
        {
            postResetRefreshQueued = true;
            postResetTimer.Stop();
            postResetTimer.Start();
        }
    }

    private static void AddDisabled(ContextMenuStrip menu, string text) { menu.Items.Add(text).Enabled = false; }
    private static bool IsStartup() { using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) return key != null && key.GetValue(StartupValue) != null; }
    private static void SetStartup(bool enabled)
    {
        using (var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            if (enabled) key.SetValue(StartupValue, "\"" + Application.ExecutablePath + "\""); else key.DeleteValue(StartupValue, false);
    }
}

internal static class Program
{
    [STAThread] private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var app = new TrayApp()) Application.Run(app);
    }
}
