using System;
using System.Drawing;
using System.Windows.Forms;

internal static class QuotaTrayCheck
{
    [STAThread] private static void Main()
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using (var font = new Font("Segoe UI Semibold", 10))
        {
            foreach (var remaining in new[] { 0, 19, 20, 39, 40, 100 })
            {
                var color = ColorTranslator.FromHtml(remaining >= 40 ? "#30A46C" : remaining >= 20 ? "#B7791F" : "#D64550");
                if (TrayApp.QuotaColor(remaining).ToArgb() != color.ToArgb()) throw new Exception("Wrong color threshold");
                var window = new QuotaWindow { Label = "5-hour usage", Remaining = remaining, Used = 100 - remaining };
                using (var host = TrayApp.NewQuotaCard(window, font))
                using (var bitmap = new Bitmap(host.Control.Width, host.Control.Height))
                {
                    host.Control.DrawToBitmap(bitmap, host.Control.ClientRectangle);
                    var expected = remaining > 0 ? color : ColorTranslator.FromHtml("#E2E5EA");
                    if (bitmap.GetPixel(16, 43).ToArgb() != expected.ToArgb()) throw new Exception("Quota bar was not painted");
                    if (host.Control.Controls[1].Text != remaining + "% left") throw new Exception("Wrong percentage label");
                    if (!host.Control.Controls[2].Text.EndsWith("Resets in --")) throw new Exception("Missing unknown reset");
                }
            }
        }
        for (var count = 0; count <= 3; count++)
        {
            var snapshot = new Snapshot();
            for (var i = 0; i < count; i++) snapshot.Windows.Add(new QuotaWindow { Remaining = i == 0 ? 100 : 0 });
            using (var icon = TrayApp.DrawIcon(snapshot))
                if (icon.Width != 32 || icon.Height != 32) throw new Exception("Wrong tray icon size");
        }
        Console.WriteLine("PASS: C# colors, painted cards, unknown resets and zero/one/two/multiple-window icons");
    }
}
