[CmdletBinding()]
param(
    [switch]$ListOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$codexRoot = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$indexPath = Join-Path $codexRoot 'session_index.jsonl'
$sessionsPath = Join-Path $codexRoot 'sessions'
$archivePath = Join-Path $codexRoot 'archived_sessions'
$backupPath = Join-Path $codexRoot 'chat-manager-backups'
$script:appVersion = '1.2.0.0'
try {
    $currentExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([IO.Path]::GetFileNameWithoutExtension($currentExecutable) -eq 'CodexChatManager') {
        $compiledVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($currentExecutable).FileVersion
        if ($compiledVersion) { $script:appVersion = $compiledVersion }
    }
} catch { }

function Get-SessionIdFromName {
    param([string]$Name)

    $match = [regex]::Match($Name, '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    return $null
}

function Get-SessionFiles {
    param([string]$Root)

    $result = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $result }

    Get-ChildItem -LiteralPath $Root -Filter '*.jsonl' -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
        $id = Get-SessionIdFromName $_.Name
        if ($id) { $result[$id] = $_.FullName }
    }
    return $result
}

function Get-LegacyCodexSessions {
    $indexed = @{}
    if (Test-Path -LiteralPath $indexPath) {
        Get-Content -LiteralPath $indexPath -Encoding UTF8 | ForEach-Object {
            if (-not [string]::IsNullOrWhiteSpace($_)) {
                try {
                    $entry = $_ | ConvertFrom-Json
                    if ($entry.id) { $indexed[$entry.id.ToLowerInvariant()] = $entry }
                }
                catch {
                    Write-Warning "Invalid line ignored in session_index.jsonl: $($_.Exception.Message)"
                }
            }
        }
    }

    $activeFiles = Get-SessionFiles $sessionsPath
    $archivedFiles = Get-SessionFiles $archivePath
    $ids = @($indexed.Keys) + @($activeFiles.Keys) + @($archivedFiles.Keys) | Sort-Object -Unique

    foreach ($id in $ids) {
        $entry = if ($indexed.ContainsKey($id)) { $indexed[$id] } else { $null }
        $isActive = $activeFiles.ContainsKey($id)
        $isArchived = $archivedFiles.ContainsKey($id)
        $state = if ($isActive -and $isArchived) { 'Duplicated' } elseif ($isArchived) { 'Archived' } elseif ($isActive) { 'Active' } else { 'Missing file' }
        $filePath = if ($isArchived) { $archivedFiles[$id] } elseif ($isActive) { $activeFiles[$id] } else { $null }
        $updated = $null
        if ($entry -and $entry.updated_at) {
            try { $updated = [DateTimeOffset]::Parse($entry.updated_at).ToLocalTime().DateTime } catch { }
        }
        if (-not $updated -and $filePath) { $updated = (Get-Item -LiteralPath $filePath).LastWriteTime }

        [pscustomobject]@{
            Id      = $id
            Name    = if ($entry -and $entry.thread_name) { [string]$entry.thread_name } else { '(untitled in index)' }
            State   = $state
            Updated = $updated
            Path    = $filePath
        }
    }
}

if (-not (Test-Path -LiteralPath $codexRoot)) {
    throw "Codex directory not found: $codexRoot"
}

function Find-CodexExecutable {
    $command = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        if ($command.Path) { return $command.Path }
        if ($command.Source) { return $command.Source }
    }

    $extensionRoots = @(
        (Join-Path $env:USERPROFILE '.vscode\extensions'),
        (Join-Path $env:USERPROFILE '.vscode-insiders\extensions')
    )

    foreach ($extensionRoot in $extensionRoots) {
        if (-not (Test-Path -LiteralPath $extensionRoot)) { continue }

        $openAiExtensions = Get-ChildItem -LiteralPath $extensionRoot -Directory -Filter 'openai.chatgpt-*' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        foreach ($extension in $openAiExtensions) {
            $candidate = Join-Path $extension.FullName 'bin\windows-x86_64\codex.exe'
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }

    return $null
}

$codexExecutable = Find-CodexExecutable
if (-not $codexExecutable) {
    if ($ListOnly) {
        throw 'codex.exe was not found in PATH or the VS Code extensions.'
    }
    Add-Type -AssemblyName System.Windows.Forms
    $message = "codex.exe was not found in PATH or the VS Code extensions.`r`n`r`nOpen Codex in VS Code at least once, then try again."
    [System.Windows.Forms.MessageBox]::Show($message, 'Codex Chat Manager', 'OK', 'Error') | Out-Null
    exit 1
}

$script:sessionSource = 'legacy index'

function Read-AppServerResponse {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$RequestId
    )

    while ($true) {
        $line = $Process.StandardOutput.ReadLine()
        if ($null -eq $line) {
            $details = $Process.StandardError.ReadToEnd().Trim()
            if (-not $details) { $details = "the app-server exited with code $($Process.ExitCode)" }
            throw "No response from the app-server: $details"
        }

        try { $message = $line | ConvertFrom-Json }
        catch { continue }

        if ($message.PSObject.Properties['id'] -and [string]$message.id -eq [string]$RequestId) {
            if ($message.PSObject.Properties['error'] -and $message.error) {
                throw "App-server error: $($message.error | ConvertTo-Json -Compress -Depth 10)"
            }
            return $message.result
        }
    }
}

function Send-AppServerRequest {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$RequestId,
        [string]$Method,
        [hashtable]$Params
    )

    $request = @{ id = $RequestId; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 10
    $Process.StandardInput.WriteLine($request)
    $Process.StandardInput.Flush()
    return Read-AppServerResponse -Process $Process -RequestId $RequestId
}

function Get-AppServerSessions {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $codexExecutable
    $startInfo.Arguments = 'app-server --stdio'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    if ($startInfo.PSObject.Properties['StandardOutputEncoding']) {
        $startInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    }
    if ($startInfo.PSObject.Properties['StandardErrorEncoding']) {
        $startInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    }
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexRoot

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $requestId = 1

    try {
        if (-not $process.Start()) { throw 'Could not start the app-server.' }

        $initialize = @{
            clientInfo = @{ name = 'codex-chat-manager'; version = $script:appVersion }
            capabilities = @{ experimentalApi = $false }
        }
        Send-AppServerRequest -Process $process -RequestId $requestId -Method 'initialize' -Params $initialize | Out-Null
        $process.StandardInput.WriteLine('{"method":"initialized","params":{}}')
        $process.StandardInput.Flush()

        foreach ($archived in @($false, $true)) {
            $cursor = $null
            do {
                $requestId++
                $parameters = @{
                    archived = $archived
                    limit = 100
                    sortKey = 'recency_at'
                    sortDirection = 'desc'
                    useStateDbOnly = $false
                }
                if ($cursor) { $parameters.cursor = $cursor }

                $page = Send-AppServerRequest -Process $process -RequestId $requestId -Method 'thread/list' -Params $parameters
                foreach ($thread in @($page.data)) {
                    $recencyProperty = $thread.PSObject.Properties['recencyAt']
                    $timestamp = if ($recencyProperty -and $recencyProperty.Value) { [long]$recencyProperty.Value } else { [long]$thread.updatedAt }
                    $updated = [DateTimeOffset]::FromUnixTimeSeconds($timestamp).ToLocalTime().DateTime
                    $nameProperty = $thread.PSObject.Properties['name']
                    $previewProperty = $thread.PSObject.Properties['preview']
                    $pathProperty = $thread.PSObject.Properties['path']
                    $name = if ($nameProperty -and $nameProperty.Value) { [string]$nameProperty.Value } elseif ($previewProperty -and $previewProperty.Value) { [string]$previewProperty.Value } else { '(untitled)' }

                    [pscustomobject]@{
                        Id      = [string]$thread.id
                        Name    = $name
                        State   = if ($archived) { 'Archived' } else { 'Active' }
                        Updated = $updated
                        Path    = if ($pathProperty -and $pathProperty.Value) { [string]$pathProperty.Value } else { $null }
                    }
                }
                $nextCursorProperty = $page.PSObject.Properties['nextCursor']
                $cursor = if ($nextCursorProperty) { $nextCursorProperty.Value } else { $null }
            } while ($cursor)
        }
    }
    finally {
        if ($process -and $process.StartInfo -and -not $process.HasExited) {
            try { $process.StandardInput.Close() } catch { }
            if (-not $process.WaitForExit(1000)) { try { $process.Kill() } catch { } }
        }
        if ($process) { $process.Dispose() }
    }
}

function Get-CodexSessions {
    try {
        $sessions = @(Get-AppServerSessions)
        if ($sessions.Count -eq 0) {
            $legacySessions = @(Get-LegacyCodexSessions)
            if ($legacySessions.Count -gt 0) {
                $script:sessionSource = 'local files (empty app-server catalog)'
                return $legacySessions
            }
        }
        $script:sessionSource = 'VS Code catalog (app-server)'
        return $sessions
    }
    catch {
        $script:sessionSource = "legacy index; app-server unavailable: $($_.Exception.Message)"
        return @(Get-LegacyCodexSessions)
    }
}

if ($ListOnly) {
    $sessions = @(Get-CodexSessions | Sort-Object Updated -Descending)
    $sessions | Format-Table State, Updated, Name, Id -AutoSize
    Write-Host "Source: $script:sessionSource"
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.IO.Compression
[System.Windows.Forms.Application]::EnableVisualStyles()

function Test-VsCodeRunning {
    return $null -ne (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue | Select-Object -First 1)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex Chat Manager'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1120, 720)
$form.MinimumSize = New-Object System.Drawing.Size(850, 520)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.ColumnCount = 1
$layout.RowCount = 3
$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48))) | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 0))) | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$form.Controls.Add($layout)

$top = New-Object System.Windows.Forms.Panel
$top.Dock = 'Fill'
$layout.Controls.Add($top, 0, 0)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = 'Search:'
$searchLabel.AutoSize = $true
$searchLabel.Location = New-Object System.Drawing.Point(12, 16)
$top.Controls.Add($searchLabel)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(82, 12)
$searchBox.Size = New-Object System.Drawing.Size(300, 24)
$top.Controls.Add($searchBox)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Refresh'
$refreshButton.Location = New-Object System.Drawing.Point(395, 10)
$refreshButton.Size = New-Object System.Drawing.Size(88, 28)
$top.Controls.Add($refreshButton)

$selectVisibleButton = New-Object System.Windows.Forms.Button
$selectVisibleButton.Text = 'Select visible'
$selectVisibleButton.Location = New-Object System.Drawing.Point(490, 10)
$selectVisibleButton.Size = New-Object System.Drawing.Size(110, 28)
$top.Controls.Add($selectVisibleButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = 'Clear selection'
$clearButton.Location = New-Object System.Drawing.Point(607, 10)
$clearButton.Size = New-Object System.Drawing.Size(95, 28)
$top.Controls.Add($clearButton)

$warningPanel = New-Object System.Windows.Forms.Panel
$warningPanel.Dock = 'Fill'
$warningPanel.BackColor = [System.Drawing.Color]::MistyRose
$warningPanel.Visible = $false
$layout.Controls.Add($warningPanel, 0, 1)

$warningLabel = New-Object System.Windows.Forms.Label
$warningLabel.Text = [char]0x26A0 + '  VS Code is running. Operations are allowed, but they may fail or remain invisible until VS Code is restarted.'
$warningLabel.AutoSize = $true
$warningLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$warningLabel.ForeColor = [System.Drawing.Color]::DarkRed
$warningLabel.Location = New-Object System.Drawing.Point(12, 10)
$warningPanel.Controls.Add($warningLabel)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'
$split.Orientation = 'Horizontal'
$split.SplitterDistance = 450
$layout.Controls.Add($split, 0, 2)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.AutoGenerateColumns = $false
$grid.MultiSelect = $true
$grid.SelectionMode = 'FullRowSelect'
$grid.RowHeadersVisible = $false
$grid.BackgroundColor = [System.Drawing.Color]::White
$grid.EditMode = 'EditOnEnter'
$grid.RowTemplate.Height = 26
$grid.ColumnHeadersHeight = 28
$split.Panel1.Controls.Add($grid)

$checkColumn = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$checkColumn.Name = 'Chosen'
$checkColumn.HeaderText = ''
$checkColumn.Width = 38
$grid.Columns.Add($checkColumn) | Out-Null

foreach ($definition in @(
    @('State', 'Status', 90),
    @('Updated', 'Activity', 145),
    @('Name', 'Conversation', 410),
    @('Id', 'UUID', 285)
)) {
    $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $column.Name = $definition[0]
    $column.HeaderText = $definition[1]
    $column.Width = $definition[2]
    $column.ReadOnly = $true
    if ($column.Name -eq 'Name') { $column.AutoSizeMode = 'Fill' }
    $grid.Columns.Add($column) | Out-Null
}

$bottom = New-Object System.Windows.Forms.Panel
$bottom.Dock = 'Fill'
$split.Panel2.Controls.Add($bottom)

$archiveButton = New-Object System.Windows.Forms.Button
$archiveButton.Text = 'Archive selected'
$archiveButton.Location = New-Object System.Drawing.Point(10, 10)
$archiveButton.Size = New-Object System.Drawing.Size(155, 32)
$bottom.Controls.Add($archiveButton)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = 'Unarchive selected'
$restoreButton.Location = New-Object System.Drawing.Point(172, 10)
$restoreButton.Size = New-Object System.Drawing.Size(160, 32)
$bottom.Controls.Add($restoreButton)

$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = 'Back up selected…'
$backupButton.Location = New-Object System.Drawing.Point(339, 10)
$backupButton.Size = New-Object System.Drawing.Size(165, 32)
$bottom.Controls.Add($backupButton)

$importButton = New-Object System.Windows.Forms.Button
$importButton.Text = 'Import backup…'
$importButton.Location = New-Object System.Drawing.Point(511, 10)
$importButton.Size = New-Object System.Drawing.Size(145, 32)
$bottom.Controls.Add($importButton)

$deleteButton = New-Object System.Windows.Forms.Button
$deleteButton.Text = 'Delete selected…'
$deleteButton.Location = New-Object System.Drawing.Point(663, 10)
$deleteButton.Size = New-Object System.Drawing.Size(160, 32)
$deleteButton.BackColor = [System.Drawing.Color]::MistyRose
$bottom.Controls.Add($deleteButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = 'Ready.'
$statusLabel.AutoSize = $true
$statusLabel.Location = New-Object System.Drawing.Point(10, 55)
$bottom.Controls.Add($statusLabel)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Location = New-Object System.Drawing.Point(10, 76)
$logBox.Anchor = 'Top,Bottom,Left,Right'
$logBox.Size = New-Object System.Drawing.Size(1075, 86)
$bottom.Controls.Add($logBox)

$script:allSessions = @()

function Write-UiLog {
    param([string]$Message)
    $logBox.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Message`r`n")
}

$script:wasVsCodeRunning = $null

function Update-VsCodeWarning {
    $isRunning = Test-VsCodeRunning
    $warningPanel.Visible = $isRunning
    $layout.RowStyles[1].Height = if ($isRunning) { 38 } else { 0 }

    if ($null -ne $script:wasVsCodeRunning -and $script:wasVsCodeRunning -ne $isRunning) {
        if ($isRunning) {
            Write-UiLog 'WARNING: VS Code detected. The manager will remain open, but concurrent operations may not have the expected effect.'
        }
        else {
            Write-UiLog 'VS Code closed. Operations are no longer competing with the extension.'
        }
    }
    $script:wasVsCodeRunning = $isRunning
}

function Show-FilteredSessions {
    $term = $searchBox.Text.Trim()
    $grid.Rows.Clear()
    $visible = @(if ($term) {
        @($script:allSessions | Where-Object { $_.Name -like "*$term*" -or $_.Id -like "*$term*" -or $_.State -like "*$term*" })
    } else { @($script:allSessions) })

    foreach ($session in $visible) {
        $updatedText = if ($session.Updated) { $session.Updated.ToString('yyyy-MM-dd HH:mm') } else { '' }
        $rowIndex = $grid.Rows.Add($false, $session.State, $updatedText, $session.Name, $session.Id)
        $grid.Rows[$rowIndex].Tag = $session
        if ($session.State -eq 'Archived') { $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::DimGray }
        elseif ($session.State -eq 'Duplicated') { $grid.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow }
    }
    $grid.ClearSelection()
    if ($grid.Rows.Count -gt 0) { $grid.FirstDisplayedScrollingRowIndex = 0 }
    $statusLabel.Text = "$($visible.Count) visible conversation(s)"
}

function Refresh-Sessions {
    try {
        $script:allSessions = @(Get-CodexSessions | Sort-Object Updated -Descending)
        Show-FilteredSessions
        Write-UiLog "List refreshed: $($script:allSessions.Count) conversation(s). Source: $script:sessionSource."
    }
    catch {
        Write-UiLog "REFRESH ERROR: $($_.Exception.Message)"
    }
}

function Get-CheckedSessions {
    if ($grid.IsCurrentCellDirty) {
        $grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null
    }
    $grid.EndEdit() | Out-Null
    $selected = @()
    foreach ($row in $grid.Rows) {
        if ($row.Cells['Chosen'].Value -eq $true -and $null -ne $row.Tag -and $row.Tag.PSObject.Properties['Id']) {
            $selected += $row.Tag
        }
    }
    return $selected
}

function Backup-Session {
    param($Session)
    if (-not $Session.Path -or -not (Test-Path -LiteralPath $Session.Path)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $destinationDir = Join-Path $backupPath "$stamp-$($Session.Id)"
    New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
    Copy-Item -LiteralPath $Session.Path -Destination $destinationDir -Force
    $metadata = [pscustomobject]@{ id = $Session.Id; name = $Session.Name; state = $Session.State; original_path = $Session.Path; backed_up_at = (Get-Date).ToString('o') }
    $metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $destinationDir 'manifest.json') -Encoding UTF8
    return $destinationDir
}

function Get-SessionStorageDirectory {
    param([string]$FileName, [string]$UpdatedAt)

    $date = $null
    $match = [regex]::Match($FileName, '^rollout-(?<date>\d{4}-\d{2}-\d{2})T')
    if ($match.Success) {
        try { $date = [DateTime]::ParseExact($match.Groups['date'].Value, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } catch { }
    }
    if (-not $date -and $UpdatedAt) {
        try { $date = [DateTimeOffset]::Parse($UpdatedAt).DateTime } catch { }
    }
    if (-not $date) { $date = Get-Date }
    return Join-Path $sessionsPath (Join-Path $date.ToString('yyyy') (Join-Path $date.ToString('MM') $date.ToString('dd')))
}

function Add-SessionIndexEntry {
    param([string]$Id, [string]$Name, [string]$UpdatedAt)

    $existingIds = @{}
    if (Test-Path -LiteralPath $indexPath) {
        Get-Content -LiteralPath $indexPath -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $entry = $_ | ConvertFrom-Json
                if ($entry.id) { $existingIds[[string]$entry.id] = $true }
            } catch { }
        }
    }
    if ($existingIds.ContainsKey($Id)) { return }

    $entryJson = [pscustomobject]@{
        id = $Id
        thread_name = $Name
        updated_at = if ($UpdatedAt) { $UpdatedAt } else { (Get-Date).ToString('o') }
    } | ConvertTo-Json -Compress
    $writer = New-Object System.IO.StreamWriter($indexPath, $true, (New-Object System.Text.UTF8Encoding($false)))
    try { $writer.WriteLine($entryJson) } finally { $writer.Dispose() }
}

function Register-ImportedSessions {
    param([object[]]$Sessions)

    if ($Sessions.Count -eq 0) { return }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $codexExecutable
    $startInfo.Arguments = 'app-server --stdio'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables['CODEX_HOME'] = $codexRoot
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $requestId = 1

    try {
        if (-not $process.Start()) { throw 'Could not start the app-server to reindex the conversations.' }
        $initialize = @{ clientInfo = @{ name = 'codex-chat-manager'; version = $script:appVersion }; capabilities = @{ experimentalApi = $true } }
        Send-AppServerRequest -Process $process -RequestId $requestId -Method 'initialize' -Params $initialize | Out-Null
        $process.StandardInput.WriteLine('{"method":"initialized","params":{}}')
        $process.StandardInput.Flush()

        foreach ($session in $Sessions) {
            $requestId++
            $parameters = @{ threadId = $session.Id; path = $session.Path; excludeTurns = $true }
            Send-AppServerRequest -Process $process -RequestId $requestId -Method 'thread/resume' -Params $parameters | Out-Null
        }
    }
    finally {
        if ($process -and $process.StartInfo -and -not $process.HasExited) {
            try { $process.StandardInput.Close() } catch { }
            if (-not $process.WaitForExit(1000)) { try { $process.Kill() } catch { } }
        }
        if ($process) { $process.Dispose() }
    }
}

function Export-SelectedBackup {
    param(
        [object[]]$Sessions,
        [string]$OutputPath,
        [switch]$Silent
    )

    $available = @($Sessions | Where-Object { $_.Path -and (Test-Path -LiteralPath $_.Path) })
    if ($available.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('The selected conversations do not have available JSONL files.', 'Create backup', 'OK', 'Information') | Out-Null
        return
    }

    if (-not $OutputPath) {
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title = 'Save a backup of the selected conversations'
        $dialog.Filter = 'Codex Chat Manager backup (*.codexbackup)|*.codexbackup|ZIP archive (*.zip)|*.zip'
        $dialog.DefaultExt = 'codexbackup'
        $dialog.AddExtension = $true
        $dialog.FileName = "codex-conversations-$(Get-Date -Format 'yyyyMMdd-HHmmss').codexbackup"
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $OutputPath = $dialog.FileName
    }

    $partialPath = "$outputPath.partial-$([Guid]::NewGuid().ToString('N'))"
    $form.UseWaitCursor = $true
    $archive = $null
    $fileStream = $null
    try {
        $fileStream = New-Object System.IO.FileStream($partialPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [IO.Compression.ZipArchiveMode]::Create, $false)
        $manifestSessions = @()
        foreach ($session in $available) {
            $statusLabel.Text = "Backup: $($session.Name)"
            [System.Windows.Forms.Application]::DoEvents()
            $fileName = [IO.Path]::GetFileName($session.Path)
            $entryName = "sessions/$($session.Id)/$fileName"
            $zipEntry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Fastest)
            $input = [IO.File]::OpenRead($session.Path)
            $output = $zipEntry.Open()
            try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
            $hash = (Get-FileHash -LiteralPath $session.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            $manifestSessions += [pscustomobject]@{
                id = $session.Id
                name = $session.Name
                state = $session.State
                updated_at = if ($session.Updated) { $session.Updated.ToString('o') } else { $null }
                file = $entryName
                sha256 = $hash
            }
        }

        $manifest = [pscustomobject]@{
            format = 'codex-chat-manager-backup'
            version = 1
            created_at = (Get-Date).ToString('o')
            conversations = $manifestSessions
        } | ConvertTo-Json -Depth 6
        $manifestEntry = $archive.CreateEntry('manifest.json', [IO.Compression.CompressionLevel]::Fastest)
        $writer = New-Object System.IO.StreamWriter($manifestEntry.Open(), (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($manifest) } finally { $writer.Dispose() }
        $archive.Dispose(); $archive = $null
        $fileStream.Dispose(); $fileStream = $null
        Move-Item -LiteralPath $partialPath -Destination $outputPath -Force
        Write-UiLog "Portable backup created with $($manifestSessions.Count) conversation(s): $outputPath"
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("Backup created with $($manifestSessions.Count) conversation(s).`r`n`r`n$outputPath", 'Backup complete', 'OK', 'Information') | Out-Null
        }
    }
    catch {
        Write-UiLog "BACKUP ERROR: $($_.Exception.Message)"
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("The backup could not be created.`r`n`r`n$($_.Exception.Message)", 'Backup error', 'OK', 'Error') | Out-Null
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
        if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue }
        $form.UseWaitCursor = $false
        $statusLabel.Text = 'Ready.'
    }
}

function Import-ConversationBackup {
    param(
        [string]$InputPath,
        [switch]$Silent
    )

    if (-not $InputPath) {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = 'Import a conversation backup'
        $dialog.Filter = 'Codex Chat Manager backup (*.codexbackup;*.zip)|*.codexbackup;*.zip|All files (*.*)|*.*'
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $InputPath = $dialog.FileName
    }

    $form.UseWaitCursor = $true
    $archive = $null
    $fileStream = $null
    $imported = @()
    $skipped = 0
    try {
        $fileStream = [IO.File]::OpenRead($InputPath)
        $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [IO.Compression.ZipArchiveMode]::Read, $false)
        $manifestEntry = $archive.GetEntry('manifest.json')
        if (-not $manifestEntry) { throw 'The archive does not contain manifest.json.' }
        $reader = New-Object System.IO.StreamReader($manifestEntry.Open(), [Text.Encoding]::UTF8)
        try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($manifest.format -ne 'codex-chat-manager-backup' -or [int]$manifest.version -ne 1) {
            throw 'Unsupported backup format or version.'
        }

        $knownFiles = Get-SessionFiles $sessionsPath
        $archivedFiles = Get-SessionFiles $archivePath
        foreach ($conversation in @($manifest.conversations)) {
            $id = [string]$conversation.id
            if ($id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
                throw "Invalid UUID in the manifest: $id"
            }
            $id = $id.ToLowerInvariant()
            if ($knownFiles.ContainsKey($id) -or $archivedFiles.ContainsKey($id)) {
                $skipped++
                Write-UiLog "Skipped (UUID already exists): $id"
                continue
            }

            $entryName = [string]$conversation.file
            if (-not $entryName.StartsWith("sessions/$id/", [StringComparison]::OrdinalIgnoreCase)) {
                throw "Invalid manifest path for $id."
            }
            $zipEntry = $archive.GetEntry($entryName)
            if (-not $zipEntry) { throw "Conversation file $id was not found in the backup." }
            $fileName = [IO.Path]::GetFileName($entryName)
            if ((Get-SessionIdFromName $fileName) -ne $id -or [IO.Path]::GetExtension($fileName) -ne '.jsonl') {
                throw "Invalid file name for conversation $id."
            }

            $destinationDir = Get-SessionStorageDirectory -FileName $fileName -UpdatedAt ([string]$conversation.updated_at)
            New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            $destination = Join-Path $destinationDir $fileName
            $partial = "$destination.partial-$([Guid]::NewGuid().ToString('N'))"
            $statusLabel.Text = "Importing: $($conversation.name)"
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $input = $zipEntry.Open()
                $output = New-Object System.IO.FileStream($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try { $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
                $actualHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($conversation.sha256 -and $actualHash -ne ([string]$conversation.sha256).ToLowerInvariant()) {
                    throw "Integrity verification failed for conversation $id."
                }
                Move-Item -LiteralPath $partial -Destination $destination
                Add-SessionIndexEntry -Id $id -Name ([string]$conversation.name) -UpdatedAt ([string]$conversation.updated_at)
                $imported += [pscustomobject]@{ Id = $id; Path = $destination }
                $knownFiles[$id] = $destination
                Write-UiLog "Imported: $($conversation.name) [$id]"
            }
            finally {
                if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
            }
        }

        if ($imported.Count -gt 0) {
            try { Register-ImportedSessions -Sessions $imported }
            catch { Write-UiLog "WARNING: import completed, but automatic reindexing failed: $($_.Exception.Message)" }
        }
        Write-UiLog "Import complete: $($imported.Count) imported, $skipped already present."
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("Import complete.`r`n`r`nImported: $($imported.Count)`r`nAlready present: $skipped`r`n`r`nIf VS Code is open, restart it to refresh the list.", 'Import backup', 'OK', 'Information') | Out-Null
        }
    }
    catch {
        Write-UiLog "IMPORT ERROR: $($_.Exception.Message)"
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("The backup could not be imported.`r`n`r`n$($_.Exception.Message)", 'Import error', 'OK', 'Error') | Out-Null
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
        $form.UseWaitCursor = $false
        Refresh-Sessions
    }
}

function Invoke-CodexBatch {
    param(
        [ValidateSet('archive', 'unarchive', 'delete')][string]$Action,
        [object[]]$Sessions
    )

    $Sessions = @($Sessions | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Id'] -and $_.PSObject.Properties['Name'] })
    if ($Sessions.Count -eq 0) {
        Write-UiLog 'No valid conversation was provided for the operation.'
        return
    }

    $form.UseWaitCursor = $true
    $success = 0
    try {
        foreach ($session in $Sessions) {
            $statusLabel.Text = "${Action}: $($session.Name)"
            [System.Windows.Forms.Application]::DoEvents()
            try {
                if ($Action -eq 'delete') {
                    $savedAt = Backup-Session $session
                    if ($savedAt) { Write-UiLog "Safety backup created: $savedAt" }
                    $output = & $codexExecutable delete --force $session.Id 2>&1 | Out-String
                }
                elseif ($Action -eq 'archive') {
                    $output = & $codexExecutable archive $session.Id 2>&1 | Out-String
                }
                else {
                    $output = & $codexExecutable unarchive $session.Id 2>&1 | Out-String
                }
                if ($LASTEXITCODE -eq 0) {
                    $success++
                    Write-UiLog "OK [$Action] $($session.Name)"
                } else {
                    Write-UiLog "FAILED [$Action] $($session.Name): $($output.Trim())"
                }
            }
            catch {
                Write-UiLog "ERROR [$Action] $($session.Name): $($_.Exception.Message)"
            }
        }
    }
    finally {
        $form.UseWaitCursor = $false
        Write-UiLog "Complete: $success of $($Sessions.Count)."
        Refresh-Sessions
    }
}

$refreshButton.Add_Click({ Refresh-Sessions })
$searchBox.Add_TextChanged({ Show-FilteredSessions })
$selectVisibleButton.Add_Click({ foreach ($row in $grid.Rows) { $row.Cells['Chosen'].Value = $true } })
$clearButton.Add_Click({ foreach ($row in $grid.Rows) { $row.Cells['Chosen'].Value = $false } })

$archiveButton.Add_Click({
    $chosen = @(Get-CheckedSessions | Where-Object { $_.State -eq 'Active' })
    if ($chosen.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one active conversation.', 'Archive', 'OK', 'Information') | Out-Null; return }
    Invoke-CodexBatch -Action archive -Sessions $chosen
})

$restoreButton.Add_Click({
    $chosen = @(Get-CheckedSessions | Where-Object { $_.State -eq 'Archived' })
    if ($chosen.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one archived conversation.', 'Unarchive', 'OK', 'Information') | Out-Null; return }
    Invoke-CodexBatch -Action unarchive -Sessions $chosen
})

$backupButton.Add_Click({
    $chosen = @(Get-CheckedSessions)
    if ($chosen.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one conversation.', 'Create backup', 'OK', 'Information') | Out-Null; return }
    Export-SelectedBackup -Sessions $chosen
})

$importButton.Add_Click({ Import-ConversationBackup })

$deleteButton.Add_Click({
    $chosen = @(Get-CheckedSessions)
    if ($chosen.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show('Select at least one conversation.', 'Delete', 'OK', 'Information') | Out-Null; return }
    $answer = [System.Windows.Forms.MessageBox]::Show("This will permanently delete $($chosen.Count) conversation(s). A safety copy of the JSONL files will be created first. Continue?", 'Confirm deletion', 'YesNo', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    $typed = [Microsoft.VisualBasic.Interaction]::InputBox("Type DELETE to confirm:", 'Final confirmation', '')
    if ($typed -cne 'DELETE') { Write-UiLog 'Deletion cancelled: confirmation text did not match.'; return }
    Invoke-CodexBatch -Action delete -Sessions $chosen
})

$vsCodeTimer = New-Object System.Windows.Forms.Timer
$vsCodeTimer.Interval = 2000
$vsCodeTimer.Add_Tick({ Update-VsCodeWarning })

$form.Add_Shown({
    Update-VsCodeWarning
    $vsCodeTimer.Start()
    Refresh-Sessions
})
$form.Add_FormClosed({ $vsCodeTimer.Stop(); $vsCodeTimer.Dispose() })
[void]$form.ShowDialog()
