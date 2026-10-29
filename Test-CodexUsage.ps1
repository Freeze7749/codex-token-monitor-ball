$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'CodexUsage.ps1')
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$r = '{"rateLimitsByLimitId":{"other":{"limitId":"other","primary":{"usedPercent":99,"windowDurationMins":60}},"codex":{"limitId":"codex","primary":{"usedPercent":28,"windowDurationMins":300,"resetsAt":1793264768},"secondary":{"usedPercent":22,"windowDurationMins":10080}}}}' | ConvertFrom-Json
$v = ConvertTo-UsageView $r
Assert ($v.Main.Remaining -eq 72) 'Codex primary must be selected independently of bucket order.'
Assert ($v.Secondary.Remaining -eq 78) 'Secondary should come from the same bucket.'
Assert ($v.Main.Label -eq '5小时') 'Primary window label.'
Assert ($v.Secondary.Label -eq '每周') 'Weekly window label.'
Assert ($v.Rows.Count -eq 3) 'All model buckets should remain visible.'
Assert ([DateTimeOffset]::Parse($v.Main.Reset).ToUnixTimeSeconds() -eq 1793264768) 'Reset timestamp conversion.'
$v = ConvertTo-UsageView ('{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":15},"secondary":null}}' | ConvertFrom-Json)
Assert ($v.Main.Remaining -eq 100) 'Zero usage is valid.'
Assert ($v.Main.Label -eq '15分钟') 'Do not assume every primary window is five hours.'
Assert ($null -eq $v.Secondary) 'Absent secondary must stay absent.'
$v = ConvertTo-UsageView ('{"rateLimits":{"primary":{"usedPercent":null}}}' | ConvertFrom-Json)
Assert ($null -eq $v.Main) 'Unknown usage must not be shown as zero.'
$v = ConvertTo-UsageView ('{"rateLimits":{"primary":{"usedPercent":120}}}' | ConvertFrom-Json)
Assert ($v.Main.Remaining -eq 0) 'Clamp over-limit percentages.'
$v = ConvertTo-UsageView ('{"rateLimits":{"primary":{"usedPercent":"NaN"}}}' | ConvertFrom-Json)
Assert ($null -eq $v.Main) 'Reject non-finite usage.'
$v = ConvertTo-UsageView ('{}' | ConvertFrom-Json)
Assert ($v.Rows.Count -eq 0) 'Empty responses must be supported.'
'PASS: 13 assertions'

