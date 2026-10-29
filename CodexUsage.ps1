# Codex app-server adapter. Never reads or logs credentials.
function Find-CodexExecutable {
    if ($env:CODEX_FLOATBALL_EXE -and (Test-Path -LiteralPath $env:CODEX_FLOATBALL_EXE)) {
        return $env:CODEX_FLOATBALL_EXE
    }
    $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    $bundled = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path $bundled) {
        $exe = Get-ChildItem $bundled -Filter codex.exe -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    # npm installs a real executable under its platform-specific vendor directory.
    $npm = Join-Path $env:APPDATA 'npm\node_modules\@openai'
    if (Test-Path $npm) {
        $exe = Get-ChildItem $npm -Filter codex.exe -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    throw '未找到 Codex。请安装 Codex 桌面版或 CLI，或设置 CODEX_FLOATBALL_EXE 为 codex.exe 的完整路径。'
}

function Get-CodexUsage {
    param([string]$Executable = (Find-CodexExecutable), [int]$TimeoutSeconds = 30)
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.FileName = $Executable
    $p.StartInfo.Arguments = 'app-server --listen stdio://'
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.CreateNoWindow = $true
    $p.StartInfo.RedirectStandardInput = $true
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    # The desktop executable can require an explicit home in restricted environments.
    $codexDir = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $p.StartInfo.EnvironmentVariables['CODEX_HOME'] = $codexDir
    try {
        [void]$p.Start()
        $stderr = $p.StandardError.ReadToEndAsync()
        $init = @{ id = 1; method = 'initialize'; params = @{
            clientInfo = @{ name = 'codex_float_ball'; title = 'Codex Float Ball'; version = '1.0.0' }
        }} | ConvertTo-Json -Depth 5 -Compress
        $p.StandardInput.WriteLine($init)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        $read = $p.StandardOutput.ReadLineAsync()
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not $read.Wait(100)) { continue }
            $line = $read.Result
            if ($null -eq $line) { throw 'Codex 服务已退出。请确认 Codex 已正常安装并登录。' }
            try { $msg = $line | ConvertFrom-Json -ErrorAction Stop } catch {
                $read = $p.StandardOutput.ReadLineAsync()
                continue
            }
            if ($null -ne $msg.id -and $msg.error) {
                # Do not expose arbitrary server output or account details in diagnostics.
                throw ('Codex 查询失败（RPC {0}）。请检查登录、网络及订阅；API Key 登录不提供订阅额度。' -f $msg.error.code)
            }
            if ($msg.id -eq 1 -and $msg.result) {
                $p.StandardInput.WriteLine('{"method":"initialized"}')
                $p.StandardInput.WriteLine('{"id":2,"method":"account/rateLimits/read"}')
            } elseif ($msg.id -eq 2 -and $msg.result) {
                return $msg.result
            }
            $read = $p.StandardOutput.ReadLineAsync()
        }
        throw '查询超时，请检查网络或代理；稍后自动重试。'
    } finally {
        try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(2000) } } catch {}
        $p.Dispose()
    }
}

function Get-WindowLabel($window, [string]$fallback) {
    if ($null -eq $window.windowDurationMins) { return $fallback }
    $minutes = [double]$window.windowDurationMins
    if ($minutes -eq 10080) { return '每周' }
    if ($minutes -ge 1440 -and $minutes % 1440 -eq 0) { return ('{0}天' -f ($minutes / 1440)) }
    if ($minutes -ge 60 -and $minutes % 60 -eq 0) { return ('{0}小时' -f ($minutes / 60)) }
    return ('{0}分钟' -f $minutes)
}

function ConvertTo-UsageView($result) {
    $buckets = @()
    if ($result.rateLimitsByLimitId) {
        $buckets = @($result.rateLimitsByLimitId.PSObject.Properties | ForEach-Object { $_.Value })
    }
    if ($buckets.Count -eq 0 -and $result.rateLimits) { $buckets = @($result.rateLimits) }
    $rows = @()
    foreach ($b in $buckets) {
        $name = if ($b.limitName) { [string]$b.limitName } elseif ($b.limitId) { [string]$b.limitId } else { 'Codex' }
        foreach ($key in @('primary', 'secondary')) {
            $w = $b.$key
            if ($null -eq $w -or $null -eq $w.usedPercent) { continue }
            $used = 0.0
            if (-not [double]::TryParse([string]$w.usedPercent, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$used)) { continue }
            if ([double]::IsNaN($used) -or [double]::IsInfinity($used)) { continue }
            $reset = $null
            if ($null -ne $w.resetsAt) {
                try { $reset = [DateTimeOffset]::FromUnixTimeSeconds([long]$w.resetsAt).ToString('o') } catch {}
            }
            $rows += [pscustomobject]@{
                Bucket = $name; Id = $b.limitId; Kind = $key
                Label = Get-WindowLabel $w $(if ($key -eq 'primary') { '主窗口' } else { '次窗口' })
                Remaining = [Math]::Max(0, [Math]::Min(100, 100 - $used))
                Used = $used; Reset = $reset
            }
        }
    }
    $main = $rows | Where-Object { $_.Id -eq 'codex' -and $_.Kind -eq 'primary' } | Select-Object -First 1
    if (-not $main) { $main = $rows | Where-Object Kind -eq 'primary' | Select-Object -First 1 }
    if (-not $main) { $main = $rows | Select-Object -First 1 }
    $secondary = $null
    if ($main) {
        $secondary = $rows | Where-Object { $_.Bucket -eq $main.Bucket -and $_.Kind -eq 'secondary' } | Select-Object -First 1
    }
    return [pscustomobject]@{ Rows = @($rows); Main = $main; Secondary = $secondary }
}

