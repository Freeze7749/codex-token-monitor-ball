param([switch]$SmokeTest)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------- 单实例 ----------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\CodexFloatBall_Mutex', [ref]$createdNew)
if (-not $createdNew) { exit }

# ---------- 路径与配置 ----------
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$SettingsPath = Join-Path $ScriptDir 'settings.json'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Codex额度悬浮球.lnk'
$PollSeconds = 180
. (Join-Path $ScriptDir 'CodexUsage.ps1')

$settings = @{ Left = -1; Top = -1 }
if (Test-Path $SettingsPath) {
    try {
        $s = Get-Content $SettingsPath -Raw | ConvertFrom-Json
        if ($null -ne $s.Left) { $settings.Left = [double]$s.Left }
        if ($null -ne $s.Top)  { $settings.Top  = [double]$s.Top }
    } catch {}
}

# ---------- 界面 ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="84" Height="84" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        ResizeMode="NoResize" Opacity="0.9">
  <Grid x:Name="Root" Cursor="Hand">
    <Ellipse Width="78" Height="78" Fill="#F01E1E22">
      <Ellipse.Effect>
        <DropShadowEffect BlurRadius="8" ShadowDepth="1" Opacity="0.5"/>
      </Ellipse.Effect>
    </Ellipse>
    <Ellipse Width="68" Height="68" Stroke="#33FFFFFF" StrokeThickness="6"/>
    <Path x:Name="Arc" StrokeThickness="6" StrokeStartLineCap="Round" StrokeEndLineCap="Round" Stroke="#3FB950"/>
    <Ellipse x:Name="FullRing" Width="68" Height="68" StrokeThickness="6" Stroke="#3FB950" Visibility="Collapsed"/>
    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
      <TextBlock x:Name="BigText" Text="--" Foreground="White" FontSize="19" FontWeight="SemiBold"
                 HorizontalAlignment="Center" FontFamily="Segoe UI"/>
      <TextBlock x:Name="SmallText" Text="Codex" Foreground="#B0FFFFFF" FontSize="10"
                 HorizontalAlignment="Center" FontFamily="Microsoft YaHei UI" Margin="0,-2,0,0"/>
    </StackPanel>
  </Grid>
</Window>
'@

$window    = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$root      = $window.FindName('Root')
$arc       = $window.FindName('Arc')
$fullRing  = $window.FindName('FullRing')
$bigText   = $window.FindName('BigText')
$smallText = $window.FindName('SmallText')

# 初始位置：上次保存的位置，否则屏幕右侧中部
$wa = [System.Windows.SystemParameters]::WorkArea
if ($settings.Left -ge $wa.Left -and $settings.Left -le ($wa.Right - 40) -and
    $settings.Top -ge $wa.Top -and $settings.Top -le ($wa.Bottom - 40)) {
    $window.Left = $settings.Left; $window.Top = $settings.Top
} else {
    $window.Left = $wa.Right - 110; $window.Top = $wa.Top + ($wa.Height / 2) - 42
}

$script:state = @{ Data = $null; Error = $null; Updated = $null; Task = $null; Worker = $null }
$script:details = $null
$script:detailsText = $null

function Get-Color([double]$remaining) {
    if ($remaining -ge 50) { return '#3FB950' }
    elseif ($remaining -ge 20) { return '#D29922' }
    else { return '#F85149' }
}

function Set-Ring([double]$fraction, [string]$color) {
    $brush = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($color)
    $arc.Stroke = $brush; $fullRing.Stroke = $brush
    if ($fraction -ge 0.999) {
        $fullRing.Visibility = 'Visible'; $arc.Data = $null; return
    }
    $fullRing.Visibility = 'Collapsed'
    if ($fraction -le 0.001) { $arc.Data = $null; return }
    $cx = 42; $cy = 42; $r = 34
    $angle = $fraction * 2 * [Math]::PI
    $x = $cx + $r * [Math]::Sin($angle)
    $y = $cy - $r * [Math]::Cos($angle)
    $large = if ($fraction -gt 0.5) { 1 } else { 0 }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $d = [string]::Format($inv, 'M {0},{1} A {2},{2} 0 {3} 1 {4},{5}', $cx, ($cy - $r), $r, $large, $x, $y)
    $arc.Data = [System.Windows.Media.Geometry]::Parse($d)
}

function Format-Reset($iso) {
    if (-not $iso) { return '' }
    try {
        if ($iso -is [DateTime]) { $t = ([DateTimeOffset]$iso.ToUniversalTime()).ToLocalTime() }
        else { $t = [DateTimeOffset]::Parse([string]$iso, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime() }
        $span = $t - [DateTimeOffset]::Now
        if ($span.TotalSeconds -le 0) { return '即将重置' }
        if ($span.TotalHours -ge 24) {
            return ('{0}天{1}小时后重置（{2}）' -f [int][Math]::Floor($span.TotalDays), $span.Hours, $t.ToString('MM-dd HH:mm'))
        }
        return ('{0}小时{1}分后重置（{2}）' -f [int][Math]::Floor($span.TotalHours), $span.Minutes, $t.ToString('HH:mm'))
    } catch { return '' }
}

function Build-Tooltip {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Codex 订阅额度')
    $lines.Add('')
    if ($script:state.Error) { $lines.Add($script:state.Error); $lines.Add('') }
    if ($script:state.Data) {
        foreach ($row in $script:state.Data.Rows) {
            $lines.Add(('{0} · {1}：剩余 {2:0}%（已用 {3:0}%）' -f $row.Bucket, $row.Label, $row.Remaining, $row.Used))
            $reset = Format-Reset $row.Reset
            if ($reset) { $lines.Add('    ' + $reset) }
        }
    }
    if ($script:state.Updated) {
        $lines.Add('')
        $lines.Add('更新于 ' + $script:state.Updated.ToString('yyyy-MM-dd HH:mm:ss'))
    }
    $lines.Add('拖动移动 · 双击刷新 · 右键菜单')
    return ($lines -join "\n").Replace('\n', [Environment]::NewLine)
}

function Update-View {
    $data = $script:state.Data
    if ($data -and $data.Main) {
        $remaining = $data.Main.Remaining
        $bigText.Text = ('{0:0}%' -f $remaining)
        $smallText.Text = if ($data.Secondary) {
            ('{0} {1:0}%' -f $data.Secondary.Label.Replace('每周','周'), $data.Secondary.Remaining)
        } else { $data.Main.Label }
        Set-Ring ($remaining / 100) (Get-Color $remaining)
    } else {
        $bigText.Text = if ($script:state.Error) { '!' } else { '--' }
        $smallText.Text = if ($script:state.Error) { '悬停查看' } else { 'Codex' }
        Set-Ring 0 '#F85149'
    }
    if ($script:state.Error -and $data -and $data.Main) { $smallText.Text = '数据较旧' }
    $root.ToolTip = Build-Tooltip
    if ($script:detailsText) { $script:detailsText.Text = Build-Tooltip }
}

function Start-Fetch {
    if ($script:state.Task) { return }
    try {
        $worker = [PowerShell]::Create()
        [void]$worker.AddScript('param($core) . $core; Get-CodexUsage').AddArgument((Join-Path $ScriptDir 'CodexUsage.ps1'))
        $script:state.Worker = $worker
        $script:state.Task = $worker.BeginInvoke()
        $smallText.Text = '刷新中…'
        $poll.Start()
    } catch {
        if ($worker) { $worker.Dispose() }
        $script:state.Worker = $null; $script:state.Task = $null
        $script:state.Error = '无法启动额度查询。'
        Update-View
    }
}

function Complete-Fetch {
    try {
        $result = @($script:state.Worker.EndInvoke($script:state.Task))
        if ($script:state.Worker.HadErrors) {
            $script:state.Error = [string]$script:state.Worker.Streams.Error[0]
        } elseif ($result.Count -gt 0) {
            $view = ConvertTo-UsageView $result[-1]
            $script:state.Data = $view
            $script:state.Updated = Get-Date
            $script:state.Error = if (-not $view.Main) {
                '当前账户未返回订阅额度。请确认使用 ChatGPT 账户登录；未知额度不会显示为 0%。'
            } else { $null }
        } else { $script:state.Error = '没有收到额度数据。' }
    } catch {
        $script:state.Error = '额度查询失败，请检查 Codex 登录及网络。'
    } finally {
        $script:state.Worker.Dispose()
        $script:state.Worker = $null
        $script:state.Task = $null
    }
    Update-View
}

function Show-Details {
    if ($script:details) { [void]$script:details.Activate(); return }
    $script:details = New-Object Windows.Window
    $script:details.Title = 'Codex 额度详情'
    $script:details.Width = 480
    $script:details.Height = 360
    $script:details.Topmost = $true
    $script:detailsText = New-Object Windows.Controls.TextBox
    $script:detailsText.IsReadOnly = $true
    $script:detailsText.TextWrapping = 'Wrap'
    $script:detailsText.VerticalScrollBarVisibility = 'Auto'
    $script:detailsText.Margin = '18'
    $script:detailsText.FontSize = 14
    $script:detailsText.Text = Build-Tooltip
    $script:details.Content = $script:detailsText
    $script:details.Add_Closed({ $script:details = $null; $script:detailsText = $null })
    $script:details.Show()
}

# 轮询后台查询（不阻塞界面）
$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(250)
$poll.Add_Tick({
    if ($script:state.Task -and $script:state.Task.IsCompleted) { $poll.Stop(); Complete-Fetch }
})

# 定时刷新
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($PollSeconds)
$timer.Add_Tick({ Start-Fetch })

# ---------- 交互 ----------
$root.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) { Start-Fetch } else { try { $window.DragMove() } catch {} }
})
$window.Add_MouseEnter({ $window.Opacity = 1.0 })
$window.Add_MouseLeave({ $window.Opacity = 0.9 })
$window.Add_LocationChanged({
    if ($SmokeTest) { return }
    try { @{ Left = $window.Left; Top = $window.Top } | ConvertTo-Json | Set-Content -Path $SettingsPath -Encoding UTF8 } catch {}
})
$root.Add_ToolTipOpening({ $root.ToolTip = Build-Tooltip })
[System.Windows.Controls.ToolTipService]::SetShowDuration($root, 60000)
[System.Windows.Controls.ToolTipService]::SetInitialShowDelay($root, 300)

function New-MenuItem([string]$header, [scriptblock]$action) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header
    $mi.Add_Click($action)
    return $mi
}

$menu = New-Object System.Windows.Controls.ContextMenu
$menu.Items.Add((New-MenuItem '立即刷新' { Start-Fetch })) | Out-Null
$menu.Items.Add((New-MenuItem '打开详细监控' { Show-Details })) | Out-Null
$autoItem = New-MenuItem '开机自动启动' {
    if (Test-Path $StartupLnk) {
        Remove-Item $StartupLnk -Force
    } else {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($StartupLnk)
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $lnk.Arguments = '"' + (Join-Path $ScriptDir '启动悬浮球.vbs') + '"'
        $lnk.WorkingDirectory = $ScriptDir
        $lnk.Save()
    }
    $autoItem.IsChecked = Test-Path $StartupLnk
}
$autoItem.IsCheckable = $false
$autoItem.IsChecked = Test-Path $StartupLnk
$menu.Items.Add($autoItem) | Out-Null
$menu.Items.Add((New-Object System.Windows.Controls.Separator)) | Out-Null
$menu.Items.Add((New-MenuItem '退出' { $window.Close() })) | Out-Null
$root.ContextMenu = $menu

$window.Add_Closed({
    $timer.Stop(); $poll.Stop()
    if ($script:details) { $script:details.Close() }
    if ($script:state.Worker) { $script:state.Worker.Stop(); $script:state.Worker.Dispose() }
    try { $mutex.ReleaseMutex() } catch {}
})

$window.Add_Loaded({
    if ($SmokeTest) {
        $script:state.Data = ConvertTo-UsageView ([pscustomobject]@{ rateLimits = [pscustomobject]@{
            limitId = 'codex'; primary = [pscustomobject]@{ usedPercent = 25; windowDurationMins = 300 }
            secondary = [pscustomobject]@{ usedPercent = 40; windowDurationMins = 10080 }
        }})
        Update-View
        Show-Details
        $script:smokeTimer = New-Object Windows.Threading.DispatcherTimer
        $script:smokeTimer.Interval = [TimeSpan]::FromSeconds(2)
        $script:smokeTimer.Add_Tick({ $script:smokeTimer.Stop(); $window.Close() })
        $script:smokeTimer.Start()
    } else { Start-Fetch; $timer.Start() }
})
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnMainWindowClose'
[void]$app.Run($window)

