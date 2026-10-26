param([switch]$Once)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = 'Stop'
$script:AppName = 'Codex Quota Tray'
$script:ScriptPath = $PSCommandPath
$script:StartupKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:StartupValue = 'CodexQuotaTray'

function Get-QuotaLabel([int]$Minutes) {
    switch ($Minutes) {
        300 { '5-hour usage' }
        1440 { '1-day usage' }
        10080 { '7-day usage' }
        default {
            if ($Minutes % 1440 -eq 0) { "$($Minutes / 1440)-day usage" }
            elseif ($Minutes % 60 -eq 0) { "$($Minutes / 60)-hour usage" }
            else { "$Minutes-minute usage" }
        }
    }
}

function Get-RelativeTime($UnixTime) {
    if ($null -eq $UnixTime) { return '--' }
    try { $seconds = [math]::Round(([DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixTime).LocalDateTime - (Get-Date)).TotalSeconds) }
    catch { return '--' }
    if ($seconds -le 0) { return 'now' }
    $days = [math]::Floor($seconds / 86400); $hours = [math]::Floor(($seconds % 86400) / 3600); $minutes = [math]::Floor(($seconds % 3600) / 60)
    if ($days -gt 0) { return "${days}d${hours}h" }
    if ($hours -gt 0) { return "${hours}h${minutes}m" }
    return "$( [math]::Max(1, $minutes) )m"
}

function Get-LatestQuota {
    $roots = @("$env:USERPROFILE\.codex\sessions", "$env:USERPROFILE\.codex\archived_sessions")
    $files = @($roots | Where-Object { Test-Path $_ } | ForEach-Object { Get-ChildItem -Path $_ -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue }) |
        Sort-Object LastWriteTime -Descending | Select-Object -First 120
    if (-not $files) { return @{ Error = 'No Codex session logs found.' } }

    $best = $null
    foreach ($file in $files) {
        try {
            $stream = [System.IO.File]::Open($file.FullName, 'Open', 'Read', 'ReadWrite')
            try {
                $offset = [math]::Max(0, $stream.Length - 1MB); $stream.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null
                $reader = [System.IO.StreamReader]::new($stream); $text = $reader.ReadToEnd(); $reader.Dispose()
            } finally { $stream.Dispose() }
        } catch { continue }
        $lines = $text -split "`n"
        [array]::Reverse($lines)
        foreach ($line in $lines) {
            if ($line -notmatch '"token_count"' -or $line -notmatch '"rate_limits"') { continue }
            try { $record = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($record.payload.type -ne 'token_count' -or $null -eq $record.payload.rate_limits) { continue }
            $limits = $record.payload.rate_limits; $windows = @()
            foreach ($prop in $limits.psobject.Properties) {
                $value = $prop.Value
                if ($null -eq $value -or $null -eq $value.used_percent -or $null -eq $value.window_minutes) { continue }
                $minutes = [int]$value.window_minutes
                if ($minutes -le 0) { continue }
                $remaining = [math]::Max(0, [math]::Min(100, 100 - [double]$value.used_percent))
                $windows += [pscustomobject]@{ Key=$prop.Name; Minutes=$minutes; Label=(Get-QuotaLabel $minutes); Used=[double]$value.used_percent; Remaining=$remaining; ResetsAt=$value.resets_at }
            }
            $windows = @($windows | Sort-Object Minutes, Key)
            if ($windows.Count -gt 0 -or $limits.rate_limit_reached_type) {
                try { $observed = [DateTimeOffset]::Parse($record.timestamp).LocalDateTime } catch { $observed = [DateTime]::MinValue }
                $snapshot = [pscustomobject]@{ Windows=$windows; Plan=$limits.plan_type; Reached=$limits.rate_limit_reached_type; Source=$file.FullName; Observed=$observed }
                if ($null -eq $best -or $snapshot.Observed -gt $best.Observed) { $best = $snapshot }
                break
            }
        }
    }
    if ($best) { return $best }
    return @{ Error = 'No rate limit event found in recent Codex logs.' }
}

# GetHicon transfers ownership to us; clone before releasing the native handle.
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class QuotaIconHandle {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr handle);
}
'@

function Get-QuotaColor([double]$Remaining) {
    if ($Remaining -ge 40) { return [System.Drawing.ColorTranslator]::FromHtml('#30A46C') }
    if ($Remaining -ge 20) { return [System.Drawing.ColorTranslator]::FromHtml('#B7791F') }
    return [System.Drawing.ColorTranslator]::FromHtml('#D64550')
}

function New-TrayIcon($Snapshot) {
    $bitmap = [System.Drawing.Bitmap]::new(32, 32)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = 'AntiAlias'; $graphics.Clear([System.Drawing.Color]::Transparent)
        # A compact terminal mark stays legible in Windows' square notification slot.
        $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::Gray, 2)
        try {
            $graphics.DrawLines($pen, [System.Drawing.Point[]]@(
                [System.Drawing.Point]::new(2, 11), [System.Drawing.Point]::new(6, 15), [System.Drawing.Point]::new(2, 19)))
            $graphics.DrawLine($pen, 6, 21, 10, 21)
        } finally { $pen.Dispose() }
        $windows = @($Snapshot.Windows | Select-Object -First 2)
        if ($windows.Count -eq 0) {
            $graphics.FillEllipse([System.Drawing.Brushes]::Gray, 17, 14, 3, 3)
            $graphics.FillEllipse([System.Drawing.Brushes]::Gray, 25, 14, 3, 3)
        }
        for ($i = 0; $i -lt $windows.Count; $i++) {
            $y = if ($windows.Count -eq 1) { 16 } else { 10 + 12 * $i }
            $remaining = [math]::Max(0, [math]::Min(100, $windows[$i].Remaining))
            $pen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(100, 128, 128, 128), 6)
            $pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            try {
                $graphics.DrawLine($pen, 16, $y, 28, $y)
                if ($remaining -gt 0) {
                    $pen.Color = Get-QuotaColor $remaining
                    $graphics.DrawLine($pen, 16, $y, [single](16 + 12 * $remaining / 100), $y)
                }
            } finally { $pen.Dispose() }
        }
        $handle = $bitmap.GetHicon()
        $borrowed = [System.Drawing.Icon]::FromHandle($handle)
        try { return @{ Icon=$borrowed.Clone() } }
        finally { $borrowed.Dispose(); [void][QuotaIconHandle]::DestroyIcon($handle) }
    } finally { $graphics.Dispose(); $bitmap.Dispose() }
}

function New-QuotaCard($Window) {
    $panel = [System.Windows.Forms.Panel]::new()
    $panel.Size = [System.Drawing.Size]::new(296, 88)
    $panel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#F7F8FA')
    $panel.Tag = $Window
    $title = [System.Windows.Forms.Label]::new()
    $title.Text = $Window.Label; $title.SetBounds(12, 10, 164, 22)
    $title.Font = $script:TitleFont
    $title.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#20242C')
    $value = [System.Windows.Forms.Label]::new()
    $value.Text = "$([math]::Round($Window.Remaining))% left"; $value.SetBounds(178, 10, 106, 22)
    $value.TextAlign = 'TopRight'; $value.Font = $script:TitleFont
    $value.ForeColor = Get-QuotaColor $Window.Remaining
    $reset = [System.Windows.Forms.Label]::new()
    $reset.Text = "$([math]::Round($Window.Used))% used  /  Resets in $(Get-RelativeTime $Window.ResetsAt)"
    $reset.SetBounds(12, 59, 272, 22); $reset.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#626B78')
    $panel.Controls.AddRange([System.Windows.Forms.Control[]]@($title, $value, $reset))
    $panel.add_Paint({
        param($sender, $e)
        $e.Graphics.SmoothingMode = 'AntiAlias'
        $pen = [System.Drawing.Pen]::new([System.Drawing.ColorTranslator]::FromHtml('#E2E5EA'), 8)
        $pen.StartCap = $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        try {
            $e.Graphics.DrawLine($pen, 16, 43, 280, 43)
            $remaining = [math]::Max(0, [math]::Min(100, $sender.Tag.Remaining))
            if ($remaining -gt 0) {
                $pen.Color = Get-QuotaColor $remaining
                $e.Graphics.DrawLine($pen, 16, 43, [single](16 + 264 * $remaining / 100), 43)
            }
        } finally { $pen.Dispose() }
    })
    $hostItem = [System.Windows.Forms.ToolStripControlHost]::new($panel)
    $hostItem.Margin = [System.Windows.Forms.Padding]::new(8, 4, 8, 4)
    return $hostItem
}

function Set-Startup([bool]$Enabled) {
    if ($Enabled) {
        $command = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:ScriptPath`""
        New-ItemProperty -Path $script:StartupKey -Name $script:StartupValue -Value $command -PropertyType String -Force | Out-Null
    } else { Remove-ItemProperty -Path $script:StartupKey -Name $script:StartupValue -ErrorAction SilentlyContinue }
}

function Test-Startup { return $null -ne (Get-ItemProperty -Path $script:StartupKey -Name $script:StartupValue -ErrorAction SilentlyContinue).$script:StartupValue }

$initial = Get-LatestQuota
if ($Once) {
    if ($initial.Error) { "Codex --`n$($initial.Error)" } else { $initial.Windows | ForEach-Object { "$($_.Label): $([math]::Round($_.Used))% used / $([math]::Round($_.Remaining))% left; reset in $(Get-RelativeTime $_.ResetsAt)" } }
    exit
}

[System.Windows.Forms.Application]::EnableVisualStyles()
$script:MenuFont = [System.Drawing.Font]::new('Segoe UI', 9)
$script:TitleFont = [System.Drawing.Font]::new('Segoe UI Semibold', 10)
$context = [System.Windows.Forms.ApplicationContext]::new()
$tray = [System.Windows.Forms.NotifyIcon]::new()
$menu = [System.Windows.Forms.ContextMenuStrip]::new(); $tray.ContextMenuStrip = $menu
$menu.Font = $script:MenuFont; $menu.BackColor = [System.Drawing.Color]::White
$menu.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#20242C')
$menu.RenderMode = 'System'; $menu.ShowImageMargin = $false
$menu.ShowCheckMargin = $true
$menu.Padding = [System.Windows.Forms.Padding]::new(4, 6, 4, 6)
$menu.ShowItemToolTips = $true
$tray.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $menu.Show([System.Windows.Forms.Cursor]::Position) }
})
$script:lastIcon = $null

function Refresh-Tray {
    $snapshot = Get-LatestQuota
    # Clear() only removes items; dispose hosted controls before rebuilding.
    while ($menu.Items.Count -gt 0) { $menu.Items[0].Dispose() }
    $item = [System.Windows.Forms.ToolStripLabel]::new('Codex Quota')
    $item.Font = $script:TitleFont; $item.Margin = [System.Windows.Forms.Padding]::new(12, 6, 12, 4)
    [void]$menu.Items.Add($item)
    if ($snapshot.Error) {
        $item = $menu.Items.Add($snapshot.Error); $item.Enabled = $false; $tray.Text = 'Codex quota: unavailable'
    } else {
        if ($snapshot.Plan) { $item = $menu.Items.Add("Plan: $($snapshot.Plan)"); $item.Enabled = $false }
        if ($snapshot.Reached) { $item = $menu.Items.Add("Limit reached: $($snapshot.Reached)"); $item.ForeColor = Get-QuotaColor 0 }
        $tooltip = @()
        foreach ($window in $snapshot.Windows) {
            [void]$menu.Items.Add((New-QuotaCard $window))
            $tooltip += "$($window.Label) $([math]::Round($window.Remaining))% left"
        }
        $item = $menu.Items.Add("Updated $($snapshot.Observed.ToString('g'))"); $item.Enabled = $false
        $item.ToolTipText = "Source: $($snapshot.Source)"
        $tray.Text = (($tooltip -join ' / ').Substring(0, [math]::Min(63, ($tooltip -join ' / ').Length)))
    }
    [void]$menu.Items.Add('-')
    $refresh = $menu.Items.Add('Refresh now'); $refresh.add_Click({ Refresh-Tray })
    $logs = $menu.Items.Add('Open session logs'); $logs.add_Click({ Start-Process "$env:USERPROFILE\.codex\sessions" })
    $startup = $menu.Items.Add('Start at login'); $startup.Checked = Test-Startup; $startup.add_Click({ Set-Startup (-not (Test-Startup)); Refresh-Tray })
    [void]$menu.Items.Add('-')
    $quit = $menu.Items.Add('Quit'); $quit.add_Click({ $tray.Visible = $false; $context.ExitThread() })
    $newIcon = New-TrayIcon $snapshot; $tray.Icon = $newIcon.Icon
    if ($script:lastIcon) { $script:lastIcon.Dispose() }
    $script:lastIcon = $newIcon.Icon
}

try {
    Refresh-Tray
    $tray.Visible = $true
    $timer = [System.Windows.Forms.Timer]::new(); $timer.Interval = 15000
    $timer.add_Tick({ if (-not $menu.Visible) { Refresh-Tray } }); $timer.Start()
    [System.Windows.Forms.Application]::Run($context)
} finally {
    if ($timer) { $timer.Dispose() }
    $tray.Dispose(); $menu.Dispose(); $context.Dispose()
    if ($script:lastIcon) { $script:lastIcon.Dispose() }
    $script:TitleFont.Dispose(); $script:MenuFont.Dispose()
}
