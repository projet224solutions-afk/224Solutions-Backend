param(
  [string]$BaseUrl = $(if ($env:BASE_URL) { $env:BASE_URL } else { "http://localhost:3000" })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:PassCount = 0
$script:FailCount = 0
$script:SkipCount = 0
$script:Results = New-Object System.Collections.Generic.List[object]

function Write-Section([string]$title) {
  Write-Host "`n=== $title ===" -ForegroundColor Cyan
}

function To-JsonObject([string]$raw) {
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { return $raw | ConvertFrom-Json } catch { return $raw }
}

function Add-Result([string]$name, [string]$status, [int]$code, $body, [string]$note = "") {
  $row = [pscustomobject]@{
    Name = $name
    Result = $status
    StatusCode = $code
    Note = $note
    Body = $body
  }
  $script:Results.Add($row)

  switch ($status) {
    "PASS" { $script:PassCount++ }
    "FAIL" { $script:FailCount++ }
    "SKIP" { $script:SkipCount++ }
  }

  $color = "White"
  if ($status -eq "PASS") { $color = "Green" }
  if ($status -eq "FAIL") { $color = "Red" }
  if ($status -eq "SKIP") { $color = "Yellow" }

  Write-Host ("[{0}] {1} (HTTP {2}) {3}" -f $status, $name, $code, $note) -ForegroundColor $color
}

function Invoke-Api(
  [string]$Method,
  [string]$Url,
  [hashtable]$Headers = @{},
  [string]$Body = "",
  [string]$ContentType = "application/json"
) {
  try {
    if ($Body -and $Body.Length -gt 0) {
      $resp = Invoke-WebRequest -Uri $Url -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body
    } else {
      $resp = Invoke-WebRequest -Uri $Url -Method $Method -Headers $Headers
    }
    return [pscustomobject]@{
      StatusCode = [int]$resp.StatusCode
      Body = To-JsonObject $resp.Content
      Raw = $resp.Content
    }
  } catch {
    if ($_.Exception.Response) {
      $response = $_.Exception.Response
      $code = [int]$response.StatusCode
      $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
      $raw = $reader.ReadToEnd()
      return [pscustomobject]@{
        StatusCode = $code
        Body = To-JsonObject $raw
        Raw = $raw
      }
    }
    throw
  }
}

function Expect-Status(
  [string]$Name,
  [object]$Resp,
  [int[]]$AllowedStatus,
  [string]$Note = ""
) {
  if ($AllowedStatus -contains $Resp.StatusCode) {
    Add-Result -name $Name -status "PASS" -code $Resp.StatusCode -body $Resp.Body -note $Note
  } else {
    Add-Result -name $Name -status "FAIL" -code $Resp.StatusCode -body $Resp.Body -note $Note
  }
}

function Require-Env([string[]]$names) {
  foreach ($n in $names) {
    if (-not (Get-Item -Path "Env:$n" -ErrorAction SilentlyContinue)) {
      return $false
    }
  }
  return $true
}

function Get-Env([string]$name) {
  $item = Get-Item -Path "Env:$name" -ErrorAction SilentlyContinue
  if ($null -eq $item) { return "" }
  return [string]$item.Value
}

function New-HmacSha256Hex([string]$secret, [string]$message) {
  $hmac = New-Object System.Security.Cryptography.HMACSHA256
  $hmac.Key = [Text.Encoding]::UTF8.GetBytes($secret)
  $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($message))
  return -join ($hash | ForEach-Object { $_.ToString("x2") })
}

Write-Host "Financial smoke tests starting against: $BaseUrl" -ForegroundColor Magenta

$jwtUser = Get-Env "JWT_USER"
$jwtAdmin = Get-Env "JWT_ADMIN"
$paymentId = Get-Env "PAYMENT_ID"
$recipientUserId = Get-Env "RECIPIENT_USER_ID"
$affiliateToken = Get-Env "AFFILIATE_TOKEN"
$testUserId = Get-Env "TEST_USER_ID"
$internalApiKey = Get-Env "INTERNAL_API_KEY"
$transactionSecret = Get-Env "TRANSACTION_SECRET_KEY"

$headersUser = @{}
if ($jwtUser) { $headersUser["Authorization"] = "Bearer $jwtUser" }

$headersAdmin = @{}
if ($jwtAdmin) { $headersAdmin["Authorization"] = "Bearer $jwtAdmin" }

# 1) Health
Write-Section "Health"
$health = Invoke-Api -Method GET -Url "$BaseUrl/health"
Expect-Status -Name "Health endpoint" -Resp $health -AllowedStatus @(200)

# 2) Payment Link
Write-Section "Payment Link"
if ($paymentId) {
  $plinkGet = Invoke-Api -Method GET -Url "$BaseUrl/api/payments/link/$paymentId"
  Expect-Status -Name "Payment link GET" -Resp $plinkGet -AllowedStatus @(200,404)

  $payBody = @{
    payment_method = "OM"
    transaction_id = "txn_smoke_$(Get-Date -Format yyyyMMddHHmmss)"
    client_info = @{
      name = "Smoke User"
      email = "smoke@example.com"
      phone = "620000000"
    }
  } | ConvertTo-Json -Depth 5

  $plinkPay = Invoke-Api -Method POST -Url "$BaseUrl/api/payments/link/$paymentId/pay" -Body $payBody
  Expect-Status -Name "Payment link PAY" -Resp $plinkPay -AllowedStatus @(200,401,403,404,409,410)
} else {
  Add-Result -name "Payment link GET" -status "SKIP" -code 0 -body $null -note "PAYMENT_ID missing"
  Add-Result -name "Payment link PAY" -status "SKIP" -code 0 -body $null -note "PAYMENT_ID missing"
}

# 3) Wallet V2
Write-Section "Wallet V2"
if ($jwtUser) {
  $wInit = Invoke-Api -Method POST -Url "$BaseUrl/api/v2/wallet/initialize" -Headers $headersUser
  Expect-Status -Name "Wallet initialize" -Resp $wInit -AllowedStatus @(200,201)

  $wBalanceBefore = Invoke-Api -Method GET -Url "$BaseUrl/api/v2/wallet/balance" -Headers $headersUser
  Expect-Status -Name "Wallet balance before" -Resp $wBalanceBefore -AllowedStatus @(200)

  $idemDeposit = "smoke-deposit-001"
  $depBody = @{
    amount = 1000
    description = "Smoke deposit"
    idempotency_key = $idemDeposit
  } | ConvertTo-Json

  $dep1 = Invoke-Api -Method POST -Url "$BaseUrl/api/v2/wallet/deposit" -Headers $headersUser -Body $depBody
  Expect-Status -Name "Wallet deposit #1" -Resp $dep1 -AllowedStatus @(200)

  $dep2 = Invoke-Api -Method POST -Url "$BaseUrl/api/v2/wallet/deposit" -Headers $headersUser -Body $depBody
  Expect-Status -Name "Wallet deposit #2 same key" -Resp $dep2 -AllowedStatus @(200)

  $withBody = @{
    amount = 500
    description = "Smoke withdraw"
    idempotency_key = "smoke-withdraw-001"
  } | ConvertTo-Json

  $wWithdraw = Invoke-Api -Method POST -Url "$BaseUrl/api/v2/wallet/withdraw" -Headers $headersUser -Body $withBody
  Expect-Status -Name "Wallet withdraw" -Resp $wWithdraw -AllowedStatus @(200,402,403)

  if ($recipientUserId) {
    $trBody = @{
      amount = 100
      recipient_id = $recipientUserId
      description = "Smoke transfer"
      idempotency_key = "smoke-transfer-001"
    } | ConvertTo-Json

    $wTransfer = Invoke-Api -Method POST -Url "$BaseUrl/api/v2/wallet/transfer" -Headers $headersUser -Body $trBody
    Expect-Status -Name "Wallet transfer" -Resp $wTransfer -AllowedStatus @(200,402,403,404)
  } else {
    Add-Result -name "Wallet transfer" -status "SKIP" -code 0 -body $null -note "RECIPIENT_USER_ID missing"
  }
} else {
  Add-Result -name "Wallet initialize" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
  Add-Result -name "Wallet balance before" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
  Add-Result -name "Wallet deposit #1" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
  Add-Result -name "Wallet deposit #2 same key" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
  Add-Result -name "Wallet withdraw" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
  Add-Result -name "Wallet transfer" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
}

# 4) Secure payment init + validate
Write-Section "Secure Payment"
if ($jwtUser -and $transactionSecret) {
  $initBody = @{
    requested_amount = 2000
    payment_method = "OM"
    transaction_type = "deposit"
    interface_type = "client"
  } | ConvertTo-Json

  $secureInit = Invoke-Api -Method POST -Url "$BaseUrl/api/payments/secure/init" -Headers $headersUser -Body $initBody
  Expect-Status -Name "Secure init #1" -Resp $secureInit -AllowedStatus @(200)

  $tx1 = ""
  $total1 = 0.0
  if ($secureInit.StatusCode -eq 200 -and $secureInit.Body) {
    try {
      $tx1 = [string]$secureInit.Body.transaction_id
      $total1 = [double]$secureInit.Body.total_amount
    } catch {}
  }

  if ($tx1) {
    $badValidateBody = @{
      transaction_id = $tx1
      external_transaction_id = "ext-smoke-bad-001"
      amount_paid = $total1
      payment_status = "SUCCESS"
      signature = "bad_signature"
    } | ConvertTo-Json

    $secureBad = Invoke-Api -Method POST -Url "$BaseUrl/api/payments/secure/validate" -Headers $headersUser -Body $badValidateBody
    Expect-Status -Name "Secure validate bad signature" -Resp $secureBad -AllowedStatus @(403)
  } else {
    Add-Result -name "Secure validate bad signature" -status "SKIP" -code 0 -body $null -note "secure init #1 did not return transaction_id"
  }

  $secureInit2 = Invoke-Api -Method POST -Url "$BaseUrl/api/payments/secure/init" -Headers $headersUser -Body $initBody
  Expect-Status -Name "Secure init #2" -Resp $secureInit2 -AllowedStatus @(200)

  $tx2 = ""
  $total2 = 0.0
  if ($secureInit2.StatusCode -eq 200 -and $secureInit2.Body) {
    try {
      $tx2 = [string]$secureInit2.Body.transaction_id
      $total2 = [double]$secureInit2.Body.total_amount
    } catch {}
  }

  if ($tx2) {
    $signature = New-HmacSha256Hex -secret $transactionSecret -message "$tx2$total2"
    $goodValidateBody = @{
      transaction_id = $tx2
      external_transaction_id = "ext-smoke-good-001"
      amount_paid = $total2
      payment_status = "SUCCESS"
      signature = $signature
    } | ConvertTo-Json

    $secureGood = Invoke-Api -Method POST -Url "$BaseUrl/api/payments/secure/validate" -Headers $headersUser -Body $goodValidateBody
    Expect-Status -Name "Secure validate good signature" -Resp $secureGood -AllowedStatus @(200)
  } else {
    Add-Result -name "Secure validate good signature" -status "SKIP" -code 0 -body $null -note "secure init #2 did not return transaction_id"
  }
} else {
  Add-Result -name "Secure init #1" -status "SKIP" -code 0 -body $null -note "JWT_USER or TRANSACTION_SECRET_KEY missing"
  Add-Result -name "Secure validate bad signature" -status "SKIP" -code 0 -body $null -note "JWT_USER or TRANSACTION_SECRET_KEY missing"
  Add-Result -name "Secure init #2" -status "SKIP" -code 0 -body $null -note "JWT_USER or TRANSACTION_SECRET_KEY missing"
  Add-Result -name "Secure validate good signature" -status "SKIP" -code 0 -body $null -note "JWT_USER or TRANSACTION_SECRET_KEY missing"
}

# 5) Affiliate
Write-Section "Affiliate"
if ($jwtUser) {
  if ($affiliateToken -and $testUserId) {
    $affBody = @{
      userId = $testUserId
      affiliateToken = $affiliateToken
      ipAddress = "127.0.0.1"
      deviceFingerprint = "smoke-fingerprint-1"
    } | ConvertTo-Json

    $affRegister = Invoke-Api -Method POST -Url "$BaseUrl/api/affiliate/register" -Headers $headersUser -Body $affBody
    Expect-Status -Name "Affiliate register" -Resp $affRegister -AllowedStatus @(201,400,403,409,429)
  } else {
    Add-Result -name "Affiliate register" -status "SKIP" -code 0 -body $null -note "AFFILIATE_TOKEN or TEST_USER_ID missing"
  }

  $affStats = Invoke-Api -Method GET -Url "$BaseUrl/api/affiliate/stats" -Headers $headersUser
  Expect-Status -Name "Affiliate stats" -Resp $affStats -AllowedStatus @(200)
} else {
  Add-Result -name "Affiliate register" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
  Add-Result -name "Affiliate stats" -status "SKIP" -code 0 -body $null -note "JWT_USER missing"
}

if ($internalApiKey) {
  $headersInternal = @{ "X-Internal-API-Key" = $internalApiKey }
  $targetUser = if ($testUserId) { $testUserId } else { "00000000-0000-0000-0000-000000000000" }
  $comBody = @{
    userId = $targetUser
    amount = 1000
    transactionType = "smoke_test"
    transactionId = "smoke-commission-001"
  } | ConvertTo-Json

  $affCommission = Invoke-Api -Method POST -Url "$BaseUrl/api/affiliate/commission" -Headers $headersInternal -Body $comBody
  Expect-Status -Name "Affiliate commission internal" -Resp $affCommission -AllowedStatus @(200,400,403)
} else {
  Add-Result -name "Affiliate commission internal" -status "SKIP" -code 0 -body $null -note "INTERNAL_API_KEY missing"
}

# Summary
Write-Section "Summary"
Write-Host ("PASS: {0} | FAIL: {1} | SKIP: {2}" -f $script:PassCount, $script:FailCount, $script:SkipCount) -ForegroundColor Magenta

$script:Results |
  Select-Object Name, Result, StatusCode, Note |
  Format-Table -AutoSize |
  Out-String |
  Write-Host

if ($script:FailCount -gt 0) {
  Write-Host "Smoke tests FAILED" -ForegroundColor Red
  exit 1
}

Write-Host "Smoke tests PASSED (with optional SKIPs possible)" -ForegroundColor Green
exit 0
