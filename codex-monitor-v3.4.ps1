param(
    [string]$Project = (Get-Location).Path,
    [int]$Interval = 3,
    [int]$StaleMinutes = 5,
    [int]$Sessions = 6,
    [int]$RecentMin = 10,
    [int]$FreshHours = 8,
    [string]$SessionsDir,
    [string]$VsCodeLogRoot,
    [switch]$OpenLog,
    [switch]$Once
)

$ErrorActionPreference = "SilentlyContinue"

# --- Environment adaptation (defaults reproduce v3.3 behavior) ---
# Sessions root: -SessionsDir > $env:CODEX_HOME/sessions > %USERPROFILE%\.codex\sessions
if (-not $SessionsDir) {
    $SessionsDir = if ($env:CODEX_HOME) { Join-Path $env:CODEX_HOME "sessions" }
                   else { Join-Path $env:USERPROFILE ".codex\sessions" }
}
# VSCode ext-host log root: -VsCodeLogRoot > $env:CODEX_MONITOR_VSCODE_LOGS > first existing of Code / Code - Insiders
if (-not $VsCodeLogRoot) { $VsCodeLogRoot = $env:CODEX_MONITOR_VSCODE_LOGS }
if (-not $VsCodeLogRoot) {
    foreach ($app in @("Code","Code - Insiders")) {
        $cand = Join-Path $env:APPDATA "$app\logs"
        if (Test-Path $cand) { $VsCodeLogRoot = $cand; break }
    }
}
if (-not $VsCodeLogRoot) { $VsCodeLogRoot = Join-Path $env:APPDATA "Code\logs" }
$script:hasGit = [bool](Get-Command git -CommandType Application -ErrorAction SilentlyContinue)

function Format-Age([double]$Seconds) {
    if ($Seconds -ge 1e12) { return "N/A" }
    $s = [int]$Seconds
    if ($s -lt 60) { return "$s s" }
    if ($s -lt 3600) { return "$([int]($s/60)) m" }
    return "$([math]::Round($s/3600,1)) h"
}

function Get-FastTailLines {
    param([string]$Path, [int]$MaxLines = 200, [long]$MaxBytes = 4194304)
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    } catch { return @() }
    try {
        $len = $fs.Length
        $window = [Math]::Min($len, $MaxBytes)
        $pos = $len - $window
        $null = $fs.Seek([long]$pos, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]$window)
        $total = 0
        while ($total -lt $window) {
            $r = $fs.Read($buf, $total, $window - $total)
            if ($r -le 0) { break }
            $total += $r
        }
    } catch { $fs.Close(); return @() } finally { if ($fs) { $fs.Dispose() } }
    if ($total -le 0) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $total)
    $lines = $text -split "`r?`n"
    if ($pos -gt 0 -and $lines.Count -gt 1) { $lines = $lines[1..($lines.Count-1)] }
    @($lines | Select-Object -Last $MaxLines)
}

function Get-FirstLine {
    param([string]$Path, [int]$MaxBytes = 65536)
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $buf = New-Object byte[] $MaxBytes
        $n = $fs.Read($buf, 0, $MaxBytes)
        $fs.Close()
    } catch { return $null }
    if ($n -le 0) { return $null }
    $text = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
    $i = $text.IndexOf("`n")
    if ($i -ge 0) { $text = $text.Substring(0, $i).TrimEnd([char]13) }
    $text
}
function Get-RecentCodexLog {
    $root = $VsCodeLogRoot
    if (-not (Test-Path $root)) { return $null }
    $candidates = @()
    Get-ChildItem $root -Directory -Force | Sort-Object LastWriteTime -Descending | ForEach-Object {
        foreach ($w in @("window1","window2","window3","window4")) {
            $p = Join-Path $_.FullName "$w\exthost\openai.chatgpt\Codex.log"
            if (Test-Path $p) { $candidates += Get-Item $p }
        }
    }
    $candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function Get-CodexProcesses {
    @(Get-Process -Name "codex" -ErrorAction SilentlyContinue) | Sort-Object Id
}

function Get-ProjectFiles {
    param([string]$Path)
    Get-ChildItem $Path -File -Recurse -Force |
        Where-Object {
            $_.FullName -notmatch "\\\.git\\" -and
            $_.FullName -notmatch "\\node_modules\\" -and
            $_.FullName -notmatch "\\\.cache\\" -and
            $_.FullName -notmatch "\\venv\\" -and
            $_.FullName -notmatch "\\bin\\" -and
            $_.FullName -notmatch "\\obj\\" -and
            $_.FullName -notmatch "\\dist\\" -and
            $_.FullName -notmatch "\\build\\"
        }
}

function Get-GitInfo([string]$Path) {
    if (-not $script:hasGit) { return [pscustomobject]@{ Branch="(git not on PATH)"; ChangedFiles=0; Added=0; Deleted=0 } }
    Push-Location $Path
    try {
        $status = @(git status --short 2>$null)
        $branch = (git symbolic-ref --short HEAD 2>$null)   # old-git compatible
        if (-not $branch) { $branch = "(detached/no git)" }
        $numstat = @(git diff --numstat 2>$null)
        $added = 0; $deleted = 0
        foreach ($line in $numstat) {
            $parts = $line -split "`t"
            if ($parts.Count -ge 2) {
                $a = 0; $d = 0
                if ([int]::TryParse($parts[0], [ref]$a)) { $added += $a }
                if ([int]::TryParse($parts[1], [ref]$d)) { $deleted += $d }
            }
        }
        [pscustomobject]@{ Branch=$branch; ChangedFiles=@($status).Count; Added=$added; Deleted=$deleted }
    } finally { Pop-Location }
}

function Get-RecentErrors([string[]]$Lines) {
    if (-not $Lines) { return @() }
    @($Lines | Where-Object { $_ -match "(?i)error|failed|exception|crash|timed out|timeout|panic" } | Select-Object -Last 3)
}

function Get-RolloutSessions {
    param([int]$Top, [string]$ProjectPath, [double]$StaleSec, [double]$FreshSec)
    $root = $SessionsDir
    if (-not (Test-Path $root)) { return @() }
    $now = Get-Date
    $files = Get-ChildItem $root -Recurse -Filter "rollout-*.jsonl" -File |
        Sort-Object LastWriteTime -Descending | Select-Object -First ($Top * 4)
    $out = @()
    foreach ($f in $files) {
        $head = Get-FirstLine $f.FullName
        $sid = "?"; $cwd = ""
        try {
            $h = ($head | ConvertFrom-Json).payload
            $sid = [string]$h.session_id
            $cwd = [string]$h.cwd
        } catch {}
        if ((-not $sid -or $sid -eq "?") -and $f.Name -match "-([0-9a-f]{8})-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$") { $sid = $Matches[1] }
        if ($sid.Length -gt 8) { $sid = $sid.Substring(0,8) }
        $tail = @(Get-FastTailLines -Path $f.FullName -MaxLines 200)
        $turnActive = $false; $lastDone = $null; $lastDoneMsg = $null
        $lastStep = ""; $pendingCall = $null; $lastCallTs = $null
        $tokens = 0
        foreach ($ln in $tail) {
            if ($ln.Length -gt 200000) {
                if ($ln -match """type""\s*:\s*""function_call_output""") { $pendingCall = $null; $lastStep = "tool result in" }
                continue
            }
            try { $o = $ln | ConvertFrom-Json } catch { continue }
            $p = $o.payload; if (-not $p) { continue }
            $pt = [string]$p.type
            switch ($pt) {
                "task_started"    { $turnActive = $true; $pendingCall = $null; $lastStep = "turn started" }
                "task_complete"   { $turnActive = $false; $lastDoneMsg = [string]$p.last_agent_message
                                    try { $lastDone = [datetime]$o.timestamp } catch {}
                                    $lastStep = "reply delivered" }
                "function_call"   { $scriptName = [string]$p.name; $sum = $scriptName
                                    try { $a = $p.arguments | ConvertFrom-Json
                                          if ($a.command) { $c = ($a.command -join " "); if ($c.Length -gt 60) { $c = $c.Substring(0,57) + "..." }; $sum = "$scriptName : $c" }
                                    } catch {}
                                    $pendingCall = $sum; $lastStep = $sum
                                    try { $lastCallTs = [datetime]$o.timestamp } catch {} }
                "function_call_output" { $pendingCall = $null; $lastStep = "tool result in" }
                "web_search_call" { $lastStep = "web search" }
                "agent_message"   { $m = ([string]$p.message) -replace "\s+"," "
                                    if ($m.Length -gt 60) { $m = $m.Substring(0,57) + "..." }
                                    $lastStep = "reply: $m" }
                "agent_reasoning" { $lastStep = "reasoning..." }
                "token_count"     { if ($p.info.total_token_usage.input_tokens) { $tokens = [double]$p.info.total_token_usage.input_tokens } }
            }
        }
        $fileAge = ($now - $f.LastWriteTime).TotalSeconds
        $status = ""; $icon = ""
        if ($turnActive) {
            if ($fileAge -lt 45)               { $status = "WORKING";              $icon = "[>]" }
            elseif ($pendingCall -and ($now - $lastCallTs).TotalSeconds -gt 45)
                                                { $status = "CMD/RUNNING?APPROVAL"; $icon = "[~]" }
            elseif ($fileAge -lt $StaleSec)    { $status = "QUIET(long step)";     $icon = "[~]" }
            else                               { $status = "STALLED?";             $icon = "[!]" }
        } else {
            $doneAge = if ($lastDone) { ($now - $lastDone).TotalSeconds } else { $fileAge }
            if ($doneAge -lt 120)              { $status = "RECENTLY ENDED";       $icon = "[+]" }
            elseif ($doneAge -lt 3600)         { $status = "IDLE";                 $icon = "[=]" }
            else                               { $status = "ENDED(old)";           $icon = "[-]" }
        }
        $match = if ($cwd -and $ProjectPath -and $cwd.StartsWith($ProjectPath, [StringComparison]::OrdinalIgnoreCase)) { "*" } else { " " }
        $doneTip = ""; if (-not $turnActive -and $lastDoneMsg) { $doneTip = ($lastDoneMsg -replace "\s+"," "); if ($doneTip.Length -gt 70) { $doneTip = $doneTip.Substring(0,67) + "..." } }
        $tokStr = if ($tokens -ge 1e6) { "{0:N1}M" -f ($tokens/1e6) } elseif ($tokens -gt 0) { "{0:N0}K" -f ($tokens/1e3) } else { "-" }
        $out += [pscustomobject]@{
            Mark=$match; Sid=$sid; Icon=$icon; Status=$status
            LastEv=(Format-Age $fileAge); Step=$(if ($turnActive) { $lastStep } else { $doneTip })
            Tok=$tokStr; Cwd=$(if ($cwd.Length -gt 30) { "..." + $cwd.Substring($cwd.Length-30) } else { $cwd })
            Fresh=$(($turnActive) -or ($fileAge -le $FreshSec))
        }
    }
    $sel = @($out | Where-Object { $_.Fresh } | Select-Object -First $Top)
    $script:sessHidden = @($out | Where-Object { -not $_.Fresh }).Count
    if ($sel.Count -eq 0 -and $out.Count -gt 0) {
        $sel = @($out | Select-Object -First 1); $script:sessHidden = $out.Count - 1; $script:sessFallback = $true
    } else { $script:sessFallback = $false }
    return $sel
}

function Get-OverallFromSessions($ses, $hasProc, $logAge, $fileAge, $staleSec) {
    if ($ses | Where-Object { $_.Status -eq "WORKING" })      { return "ACTIVE" }
    if ($ses | Where-Object { $_.Icon -in @("[~]","[!]") })    { return "WORKING (quiet) / CHECK" }
    if ($ses | Where-Object { $_.Status -eq "RECENTLY ENDED" }) { return "RECENTLY ENDED" }
    if ($fileAge -lt 30 -or $logAge -lt 30)                    { return "ACTIVE (file/log only)" }
    if ($hasProc)                                              { return "IDLE" }
    return "NO ACTIVE CODEX"
}

function Get-Fingerprint($health, $ses, $git, $codexCount, $totalMemory, $errors, $recentNames) {
    $parts = @($health, $git.Branch, $git.ChangedFiles, $git.Added, $git.Deleted, $codexCount, [int]($totalMemory/32))
    $parts += ($recentNames -join ",")
    foreach ($s in $ses) { $parts += ("" + $s.Mark + $s.Sid + $s.Icon + $s.Status + $s.Step) }
    foreach ($e in $errors) {
        $norm = ($e -replace "^\d{4}-\d{2}-\d{2}[T ]?[\d:\.]+Z?\s*", "")
        $parts += $norm.Substring(0, [Math]::Min(60, $norm.Length))
    }
    ($parts -join "|")
}

function Test-Key { try { return [Console]::KeyAvailable } catch { return $false } }
function Read-Key  { try { return [Console]::ReadKey($true) } catch { return $null } }

if (-not (Test-Path $Project)) { Write-Host "Project path not found: $Project"; exit 1 }
$Project = (Resolve-Path $Project).Path

if ($OpenLog) {
    $logToOpen = Get-RecentCodexLog
    if ($logToOpen) { if (Get-Command code -CommandType Application -ErrorAction SilentlyContinue) { code --reuse-window $logToOpen.FullName } else { Start-Process $logToOpen.FullName }; exit } else { Write-Host "Codex.log not found."; exit 1 }
}

Write-Host "Codex monitor v3.4 : initial scan running, first frame will appear shortly... (q quits)"
$prevFp = ""; $lastRender = [DateTime]::MinValue; $lastChange = Get-Date
$paused = $false; $force = $true

while ($true) {
    while (Test-Key) {
        $k = Read-Key; if (-not $k) { break }
        if ($k.Key -eq [ConsoleKey]::Spacebar) { $paused = -not $paused; $force = $true }
        elseif ($k.KeyChar -eq "q" -or $k.KeyChar -eq "Q") { exit }
        elseif ($k.KeyChar -eq "r" -or $k.KeyChar -eq "R") { $force = $true }
    }

    $now = Get-Date
    $staleSec = $StaleMinutes * 60
    $log = Get-RecentCodexLog
    $codex = @(Get-CodexProcesses)
    if ($force -or -not $script:cacheAt -or ($now - $script:cacheAt).TotalSeconds -ge 15) {
        $script:cacheFiles = @(Get-ProjectFiles $Project | Sort-Object LastWriteTime -Descending)
        $script:cacheGit = Get-GitInfo $Project
        $script:cacheAt = $now
    }
    $allFiles = $script:cacheFiles
    $latestFile = $allFiles | Select-Object -First 1
    $recentCut = $now.AddMinutes(-$RecentMin)
    $recent = @($allFiles | Where-Object { $_.LastWriteTime -gt $recentCut } | Select-Object -First 10)
    $git = $script:cacheGit
    $ses = @(Get-RolloutSessions -Top $Sessions -ProjectPath $Project -StaleSec $staleSec -FreshSec ($FreshHours * 3600))

    $fileAge = if ($latestFile) { ($now - $latestFile.LastWriteTime).TotalSeconds } else { [double]::MaxValue }
    $logAge  = if ($log) { ($now - $log.LastWriteTime).TotalSeconds } else { [double]::MaxValue }
    $logTail = if ($log) { @(Get-FastTailLines -Path $log.FullName -MaxLines 80) } else { @() }
    $errors  = @(Get-RecentErrors $logTail)
    $health  = Get-OverallFromSessions $ses ($codex.Count -gt 0) $logAge $fileAge $staleSec

    $totalMemory = 0.0; $started = $null
    foreach ($proc in $codex) {
        if ($proc) { $totalMemory += $proc.WorkingSet64 / 1MB; if (-not $started -or $proc.StartTime -lt $started) { $started = $proc.StartTime } }
    }

    $fp = Get-Fingerprint $health $ses $git $codex.Count $totalMemory $errors @($recent.Name)
    $changed = ($fp -ne $prevFp)
    $heartbeat = ((Get-Date) - $lastRender).TotalSeconds -gt 60
    $doRender = $false
    if ($paused) {
        if ($force) { $doRender = $true; $force = $false }
    } elseif ($changed -or $heartbeat -or $force) {
        $gap = ((Get-Date) - $lastRender).TotalSeconds
        $minGap = if ($force) { 1 } else { 5 }
        if ($gap -ge $minGap) {
            $doRender = $true; $force = $false
            if ($changed) { $lastChange = $now }
            $prevFp = $fp
        }
    }

    if ($doRender) {
        Clear-Host
        Write-Host "================================================================"
        if ($paused) { Write-Host "  >>>  PAUSED (Space resumes)  <<<" }
        Write-Host "                 CODEX AGENT MONITOR v3.4"
        Write-Host "================================================================"
        Write-Host ("Project       : {0}" -f $Project)
        Write-Host ("Time          : {0}" -f $now.ToString("yyyy-MM-dd HH:mm:ss"))
        Write-Host ("Status        : {0}   (no change for {1})" -f $health, (Format-Age ((Get-Date) - $lastChange).TotalSeconds))
        if ($started) {
            $rt = New-TimeSpan -Start $started -End $now
            Write-Host ("Runtime       : {0:00}:{1:00}:{2:00}   Mem: {3:N0} MB" -f [int]$rt.TotalHours, $rt.Minutes, $rt.Seconds, $totalMemory)
        } else { Write-Host "Runtime       : N/A" }

        Write-Host ""
        Write-Host "---------------------- SESSIONS (rollout) ----------------------"
        Write-Host ("  {0} {1,-8} {2,-4} {3,-20} {4,-8} {5,-6} {6}" -f "*","sid","ic","status","lastEv","tok","current step / last reply")
        foreach ($s in $ses) {
            $l = $s.Step; if ($l.Length -gt 58) { $l = $l.Substring(0,55) + "..." }
            Write-Host ("  {0} {1,-8} {2,-4} {3,-20} {4,-8} {5,-6} {6}" -f $s.Mark, $s.Sid, $s.Icon, $s.Status, $s.LastEv, $s.Tok, $l)
        }
        Write-Host "  icons: [>]working  [~]long-step/approval?  [!]stalled?  [+]ended<2m  [=]idle"
        if ($script:sessHidden -gt 0) {
            if ($script:sessFallback) { Write-Host ("  (no session in last {0}h - showing latest 1 only; {1} older hidden; widen with -FreshHours)" -f $FreshHours, $script:sessHidden) }
            else { Write-Host ("  ({0} older sessions hidden by {1}h freshness rule; widen with -FreshHours)" -f $script:sessHidden, $FreshHours) }
        }

        Write-Host ""
        Write-Host "-------------------------- ACTIVITY ----------------------------"
        Write-Host ("Last file     : {0}   ({1})" -f (Format-Age $fileAge), $(if ($latestFile) { $latestFile.Name } else { "N/A" }))
        Write-Host ("VSCode log    : {0}" -f (Format-Age $logAge))
        Write-Host ""
        Write-Host "----------------------------- GIT ------------------------------"
        Write-Host ("Branch        : {0}   changed: {1}   diff: +{2} / -{3}" -f $git.Branch, $git.ChangedFiles, $git.Added, $git.Deleted)
        Write-Host ""
        Write-Host ("----------------- RECENT WRITES (last {0}m, top 10) --------------" -f $RecentMin)
        if ($recent.Count -eq 0) {
            Write-Host "  (none in window)"
        } else {
            foreach ($rf in $recent) {
                $rel = $rf.FullName.Substring($Project.TrimEnd([char]92).Length).TrimStart([char]92)
                Write-Host ("  {0,-8} {1}" -f (Format-Age ((Get-Date) - $rf.LastWriteTime).TotalSeconds), $rel)
            }
        }
        Write-Host ""
        Write-Host "--------------------------- ALERTS ------------------------------"
        if ($errors.Count -gt 0) {
            foreach ($e in $errors) { $c = ($e -replace "\s+"," ").Trim(); if ($c.Length -gt 100) { $c = $c.Substring(0,97) + "..." }; Write-Host ("! {0}" -f $c) }
        } else { Write-Host "No recent error-like lines." }
        Write-Host ""
        Write-Host "================================================================"
        Write-Host ("poll {0}s | stale {1}m | fresh {2}h | Space=pause  r=redraw  q=quit | redraw on change, min gap 5s (60s heartbeat)" -f $Interval, $StaleMinutes, $FreshHours)

        $lastRender = Get-Date
    }

    if ($Once) { break }
    Start-Sleep -Seconds $Interval
}
