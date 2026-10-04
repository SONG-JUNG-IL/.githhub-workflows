<#
.SYNOPSIS
  원 PC 사전 점검 스크립트 (읽기 전용 · 비식별 결과 파일 1개 생성)

.DESCRIPTION
  Claude CLI 기반 작업 환경을 원 PC 에서 운영하기 위한 사전 정보를 수집한다.
  - 하는 일: 버전/사양 조회, 외부 연결 가능 여부 확인(HEAD 요청 1회씩), 결과 파일 저장
  - 하지 않는 일: 파일 삭제/수정, 데이터 폴더 열람, 계정/토큰/키 조회, 설치
  - 결과 파일: 바탕화면 precheck_결과_<시각>.txt  (사용자명/PC명은 <USER>/<PC> 로 치환)
  - 반출 전 결과 파일을 직접 열어 확인하고, 반출 승인 절차를 따른다.

.NOTES
  실행: 터미널(Windows Terminal)에서
        powershell -NoProfile -ExecutionPolicy Bypass -File .\precheck.ps1
  이 파일은 UTF-8 BOM 으로 저장되어 있어야 한글이 깨지지 않는다.
#>

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$out   = Join-Path ([Environment]::GetFolderPath('Desktop')) "precheck_결과_$stamp.txt"
$lines = New-Object System.Collections.Generic.List[string]

function Add-Line {
    <# 결과 목록과 화면에 한 줄 추가 #>
    param([string]$Text)
    $lines.Add($Text) | Out-Null
    Write-Host $Text
}

function Mask {
    <# 사용자명/PC명을 치환하여 식별 정보를 줄인다 #>
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text
    if ($env:USERNAME)     { $t = $t -replace [regex]::Escape($env:USERNAME), '<USER>' }
    if ($env:COMPUTERNAME) { $t = $t -replace [regex]::Escape($env:COMPUTERNAME), '<PC>' }
    return $t
}

function Get-FirstLine {
    <# 외부 명령 실행 후 첫 줄만 반환 (없으면 '미설치/실행 불가') #>
    param([string]$Cmd, [string[]]$CmdArgs)
    try {
        $r = & $Cmd @CmdArgs 2>&1 | Select-Object -First 1
        if ($null -eq $r) { return '(출력 없음)' }
        return (Mask ([string]$r))
    } catch {
        return '미설치/실행 불가'
    }
}

function Test-Endpoint {
    <# HTTPS 도달 가능 여부만 확인 (본문은 읽지 않음). 결과: 상태코드 또는 실패 사유 #>
    param([string]$Url, [int]$TimeoutSec = 8)
    try {
        $resp = Invoke-WebRequest -Uri $Url -Method Head -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        return "도달 가능 (HTTP $([int]$resp.StatusCode))"
    } catch {
        $ex = $_.Exception
        # 서버가 응답했으면(예: 401/403/405) 네트워크 경로는 열려 있다는 뜻
        if ($ex.Response -and $ex.Response.StatusCode) {
            return "도달 가능 (HTTP $([int]$ex.Response.StatusCode) — 서버 응답 있음)"
        }
        $msg = ($ex.Message -split "`n")[0]
        return "차단/실패: $(Mask $msg)"
    }
}

Add-Line "===== 원 PC 사전 점검 · $stamp ====="
Add-Line ''

# ---------------------------------------------------------------- 1. 환경
Add-Line '[1] 환경'
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) { Add-Line ("OS: {0} / 빌드 {1} / {2}" -f $os.Caption, $os.BuildNumber, $os.OSArchitecture) }
Add-Line ("PowerShell: $($PSVersionTable.PSVersion)")
Add-Line ("Python: " + (Get-FirstLine 'python' @('--version')))
Add-Line ("Python 경로: " + (Get-FirstLine 'python' @('-c', 'import sys; print(sys.executable)')))
Add-Line ("pip: " + (Get-FirstLine 'python' @('-m', 'pip', '--version')))
Add-Line ("Git: " + (Get-FirstLine 'git' @('--version')))
Add-Line ("Claude CLI: " + (Get-FirstLine 'claude' @('--version')))
Add-Line ("dciodvfy: " + $(if (Get-Command dciodvfy -ErrorAction SilentlyContinue) { '발견(PATH)' } else { 'PATH 에 없음' }))
Add-Line ''

# ---------------------------------------------------------------- 2. 사양
Add-Line '[2] 하드웨어 (대용량 CT 처리 설계 기준)'
$cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
if ($cpu) { Add-Line ("CPU: {0} / 코어 {1} / 논리 {2}" -f $cpu.Name.Trim(), $cpu.NumberOfCores, $cpu.NumberOfLogicalProcessors) }
if ($os) { Add-Line ("RAM: 전체 {0:N1} GB / 여유 {1:N1} GB" -f ($os.TotalVisibleMemorySize / 1MB), ($os.FreePhysicalMemory / 1MB)) }
Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
    Add-Line ("디스크 {0} 전체 {1:N0} GB / 여유 {2:N0} GB" -f $_.DeviceID, ($_.Size / 1GB), ($_.FreeSpace / 1GB))
}
Add-Line ''

# ---------------------------------------------------------------- 3. 연결
Add-Line '[3] 외부 연결 (HEAD 요청 1회씩 · 본문 미수신)'
$targets = [ordered]@{
    'Anthropic API (api.anthropic.com)' = 'https://api.anthropic.com'
    'Claude 웹 (claude.ai)'              = 'https://claude.ai'
    'GitHub (github.com)'                = 'https://github.com'
    'PyPI (pypi.org)'                    = 'https://pypi.org'
}
foreach ($k in $targets.Keys) {
    Add-Line ("{0}: {1}" -f $k, (Test-Endpoint $targets[$k]))
}
$proxyNames = 'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'ANTHROPIC_BASE_URL'
foreach ($n in $proxyNames) {
    $v = [Environment]::GetEnvironmentVariable($n)
    if ($v) {
        # 주소 속 계정:암호@ 부분 제거
        $safe = Mask ($v -replace '//[^@/]+@', '//<자격증명 제거>@')
        Add-Line ("환경변수 {0}: {1}" -f $n, $safe)
    } else {
        Add-Line ("환경변수 {0}: (없음)" -f $n)
    }
}
Add-Line ''

# ---------------------------------------------------------------- 4. 패키지
Add-Line '[4] Python 패키지 (pip freeze · 폐쇄 환경 재현용)'
try {
    $freeze = & python -m pip freeze 2>&1
    Add-Line ("패키지 수: {0}" -f @($freeze).Count)
    foreach ($p in $freeze) { Add-Line ("  " + (Mask ([string]$p))) }
} catch {
    Add-Line 'pip freeze 실행 불가'
}
Add-Line ''

# ---------------------------------------------------------------- 5. 수동 확인
Add-Line '[5] 사람이 직접 확인할 항목 (스크립트가 조회하지 않음 — README 의 체크리스트 사용)'
Add-Line '  - Claude CLI 로그인 방식 (계정 / API 키 / 기관 계약)'
Add-Line '  - claude remote-control 시험 실행 결과'
Add-Line '  - 보안 담당부서 회신 (대화 내용의 외부 전송 허용 범위)'

$utf8Bom = New-Object System.Text.UTF8Encoding $true
[IO.File]::WriteAllLines($out, $lines, $utf8Bom)
Write-Host ''
Write-Host "결과 파일: $out" -ForegroundColor Green
Write-Host '반출 전에 파일을 열어 식별 정보가 없는지 확인하십시오.' -ForegroundColor Yellow
