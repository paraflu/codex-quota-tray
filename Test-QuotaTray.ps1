param([string]$PreviewPath)
$ErrorActionPreference = 'Stop'
# Load definitions and UI setup, without reading real logs or starting the message loop.
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    "$PSScriptRoot\CodexQuotaTray.ps1", [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$loading = $true
foreach ($statement in $ast.EndBlock.Statements) {
    $text = $statement.Extent.Text
    if ($text -eq '$initial = Get-LatestQuota') { $loading = $false }
    if ($text -eq '[System.Windows.Forms.Application]::EnableVisualStyles()') { $loading = $true }
    if ($statement -is [System.Management.Automation.Language.TryStatementAst]) { break }
    if ($loading) { . ([scriptblock]::Create($text)) }
}
function Test-Startup { return $false }
function Get-LatestQuota { return $script:TestSnapshot }
try {
    foreach ($case in @(@{Value=0; Color='#D64550'}, @{Value=19; Color='#D64550'},
        @{Value=20; Color='#B7791F'}, @{Value=39; Color='#B7791F'},
        @{Value=40; Color='#30A46C'}, @{Value=100; Color='#30A46C'})) {
        if ((Get-QuotaColor $case.Value).ToArgb() -ne [System.Drawing.ColorTranslator]::FromHtml($case.Color).ToArgb()) {
            throw "Wrong threshold color: $($case.Value)"
        }
    }
    foreach ($count in 0, 1, 2, 3) {
        $windows = @(for ($i = 0; $i -lt $count; $i++) {
            [pscustomobject]@{ Label=(Get-QuotaLabel (@(300,10080,43200)[$i])); Remaining=(@(72,15,0)[$i]);
                Used=(@(28,85,100)[$i]); ResetsAt=([DateTimeOffset]::Now.ToUnixTimeSeconds() + 7200) }
        })
        $script:TestSnapshot = [pscustomobject]@{Windows=$windows; Plan='plus'; Observed=(Get-Date); Source='test.jsonl'}
        Refresh-Tray
        $cards = @($menu.Items | Where-Object { $_ -is [System.Windows.Forms.ToolStripControlHost] })
        if ($cards.Count -ne $count) { throw 'Missing quota cards' }
        foreach ($card in $cards) {
            $panel = $card.Control
            if ($panel.Controls[1].Text -ne "$($panel.Tag.Remaining)% left") { throw 'Wrong percentage label' }
            $bitmap = [System.Drawing.Bitmap]::new($panel.Width, $panel.Height)
            try {
                $panel.DrawToBitmap($bitmap, $panel.ClientRectangle)
                $expected = if ($panel.Tag.Remaining -gt 0) { Get-QuotaColor $panel.Tag.Remaining } else {
                    [System.Drawing.ColorTranslator]::FromHtml('#E2E5EA')
                }
                if ($bitmap.GetPixel(16,43).ToArgb() -ne $expected.ToArgb()) { throw 'Quota bar was not painted' }
            } finally { $bitmap.Dispose() }
        }
        # A second refresh exercises disposal/replacement of hosted controls and HICONs.
        Refresh-Tray
        if ($count -eq 2 -and $PreviewPath) {
            $menu.Show([System.Drawing.Point]::new(10,10))
            [System.Windows.Forms.Application]::DoEvents()
            $bitmap = [System.Drawing.Bitmap]::new($menu.Width, $menu.Height)
            try {
                $menu.DrawToBitmap($bitmap, $menu.ClientRectangle)
                $bitmap.Save([IO.Path]::GetFullPath($PreviewPath))
            } finally { $bitmap.Dispose(); $menu.Close() }
        }
    }
    $script:TestSnapshot = @{Error='No Codex session logs found.'}
    Refresh-Tray
    if ($tray.Text -ne 'Codex quota: unavailable') { throw 'Missing error state' }
    if (-not $tray.Icon -or $tray.Icon.Width -ne 32) { throw 'Missing tray icon' }
    'PASS: colors, cards, painted bars, refresh, empty/error states and tray icons'
} finally {
    $tray.Dispose(); $menu.Dispose(); $context.Dispose()
    if ($script:lastIcon) { $script:lastIcon.Dispose() }
    $script:TitleFont.Dispose(); $script:MenuFont.Dispose()
}
