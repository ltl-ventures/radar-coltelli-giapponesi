#requires -Version 5.1
<#
    L054 — Radar Coltelli Giapponesi : availability / price monitor

    Design source of truth:
      03_Opportunities/L054/Experiment_Plan/Monitoring_Operations_28D.md
      03_Opportunities/L054/Experiment_Plan/Monitoring_Red_Team_2026-09-05.md

    SAFETY MODEL
      - Default mode is 'dry-run'. Nothing is written or committed unless -Mode write.
      - ALL network access goes through Invoke-Source (the gateway). Nothing else may
        issue a request. The gateway refuses affiliate/tracking URLs before the request
        and re-validates the final URL after redirects.
      - data/products.json is the only durable state. No state/log/signal files exist.
      - Only disponibilita, prezzo and ultimo_controllo may ever be modified.

    Written for Windows PowerShell 5.1 syntax so the same file runs under pwsh 7 on
    ubuntu-latest (production) and locally as a fallback. Note: parsing the multi-MB
    SharpEdge feed is validated on pwsh 7; 5.1 may struggle on the largest pages.
#>

[CmdletBinding()]
param(
    [ValidateSet('dry-run', 'write', 'verify', 'selftest')]
    [string] $Mode = 'dry-run',

    [switch] $ForceDeploy,

    # Confirmation wait. Production ~3600s; tests override.
    [int] $ConfirmWaitSeconds = 3600,

    [string] $RepoRoot = '',

    # verify mode: the SHA whose data the live site must match
    [string] $ExpectRef = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $here = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($here)) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $RepoRoot = Split-Path -Parent $here
}

# ---------------------------------------------------------------- constants --

$SITE_BASE       = 'https://ltl-ventures.github.io/radar-coltelli-giapponesi'
$SHARPEDGE_FEED  = 'https://sharpedgeshop.com/products.json'
$HOCHO_HOST      = 'https://www.hocho-knife.com'
$MAX_FEED_PAGES  = 20
$STALE_HOURS     = 36
$SANITY_LOW      = 0.5
$SANITY_HIGH     = 2.0
$EXPECTED_ROWS   = 28
$PRODUCTS_REL    = 'data/products.json'

# Fields the monitor is permitted to change. Everything else is immutable.
$MUTABLE_FIELDS  = @('disponibilita', 'prezzo', 'ultimo_controllo')

# Affiliate / tracking parameters the gateway must never request.
$AFFILIATE_RX    = '(?i)(sca_ref|aff=|utm_[a-z]+|a_aid|clickref|partner_id)'

$INV = [Globalization.CultureInfo]::InvariantCulture

$script:GatewayCalls   = 0
$script:GatewayRefusals = 0
$script:Warnings       = New-Object System.Collections.ArrayList
$script:Escalations    = New-Object System.Collections.ArrayList

function Write-Info    { param($m) Write-Host "[info ] $m" }
function Write-Warn    { param($m) [void]$script:Warnings.Add($m); Write-Host "[warn ] $m" }
function Add-Escalation{ param($m) [void]$script:Escalations.Add($m); Write-Host "[ESCAL] $m" }

# ------------------------------------------------------------------ gateway --
# The ONLY place in this codebase permitted to perform a network request.

function Invoke-Source {
    param(
        [Parameter(Mandatory = $true)][string] $Url,
        [int] $TimeoutSec = 30,
        [switch] $NoCache
    )

    # Pre-request assertion. Refuse before a packet is sent.
    if ($Url -match $AFFILIATE_RX) {
        $script:GatewayRefusals++
        throw "GATEWAY REFUSED (pre-request): affiliate/tracking parameter in URL -> $Url"
    }
    if ($Url -notmatch '^https://') {
        throw "GATEWAY REFUSED: non-https URL -> $Url"
    }

    $headers = @{ 'User-Agent' = 'radar-coltelli-giapponesi-monitor/1.0 (+https://github.com/ltl-ventures/radar-coltelli-giapponesi)' }
    if ($NoCache) { $headers['Cache-Control'] = 'no-cache'; $headers['Pragma'] = 'no-cache' }

    $resp = Invoke-WebRequest -Uri $Url -Headers $headers -TimeoutSec $TimeoutSec -UseBasicParsing
    $script:GatewayCalls++

    # Post-redirect assertion: validate where we actually landed.
    $final = $null
    try {
        if ($resp.BaseResponse.PSObject.Properties.Name -contains 'ResponseUri') {
            $final = $resp.BaseResponse.ResponseUri.AbsoluteUri              # PS 5.1
        } elseif ($resp.BaseResponse.PSObject.Properties.Name -contains 'RequestMessage') {
            $final = $resp.BaseResponse.RequestMessage.RequestUri.AbsoluteUri # PS 7
        }
    } catch { $final = $null }

    if ($final -and ($final -match $AFFILIATE_RX)) {
        $script:GatewayRefusals++
        throw "GATEWAY REFUSED (post-redirect): landed on affiliate URL -> $final"
    }

    return $resp.Content
}

function Invoke-SourceWithRetry {
    param([string] $Url, [switch] $NoCache)
    $delays = @(0, 5, 15)
    $last = $null
    foreach ($d in $delays) {
        if ($d -gt 0) { Start-Sleep -Seconds $d }
        try {
            if ($NoCache) { return Invoke-Source -Url $Url -NoCache }
            return Invoke-Source -Url $Url
        } catch {
            # A gateway refusal is a hard programming error: never retry it.
            if ($_.Exception.Message -like 'GATEWAY REFUSED*') { throw }
            $last = $_.Exception.Message
        }
    }
    throw "source unavailable after retries: $Url :: $last"
}

# -------------------------------------------------------------- url helpers --

function Get-PlainUrl {
    param([string] $Url)
    return ($Url -split '\?')[0]
}

function Get-SharpEdgeHandle {
    param([string] $StoredUrl)
    $plain = Get-PlainUrl $StoredUrl
    return ($plain -split '/products/')[-1].TrimEnd('/')
}

function Get-HochoPlainUrl {
    param([string] $StoredUrl)
    # Rebuild from the path only. NEVER request the stored (affiliate) URL.
    $plain = Get-PlainUrl $StoredUrl
    $u = [Uri]$plain
    $slug = $u.AbsolutePath.Trim('/')
    if (-not $slug) { throw "cannot derive Hocho slug from: $StoredUrl" }
    return "$HOCHO_HOST/$slug/"
}

# ------------------------------------------------------------ source: feed ---

function Get-SharpEdgeCatalog {
    <# Pages until an empty page. Hard cap. Returns hashtable handle -> observation. #>
    $index = @{}
    $page = 1
    while ($true) {
        if ($page -gt $MAX_FEED_PAGES) {
            throw "SharpEdge feed exceeded $MAX_FEED_PAGES pages - refusing to continue"
        }
        $body = Invoke-SourceWithRetry -Url ("{0}?limit=250&page={1}" -f $SHARPEDGE_FEED, $page)
        $data = $body | ConvertFrom-Json
        if (-not ($data.PSObject.Properties.Name -contains 'products')) {
            throw "SharpEdge feed schema error: no 'products' key on page $page"
        }
        $products = @($data.products)
        if ($products.Count -eq 0) { break }

        foreach ($p in $products) {
            if (-not $p.handle) { continue }
            $v = @($p.variants)[0]
            if ($null -eq $v) { continue }

            # P0-5: a missing 'available' is a SCHEMA FAILURE, never "sold out".
            $hasAvail = ($v.PSObject.Properties.Name -contains 'available') -and ($null -ne $v.available)
            $hasPrice = ($v.PSObject.Properties.Name -contains 'price')     -and ($null -ne $v.price)

            $index[$p.handle] = [pscustomobject]@{
                handle       = $p.handle
                title        = $p.title
                hasAvail     = $hasAvail
                hasPrice     = $hasPrice
                available    = $(if ($hasAvail) { [bool]$v.available } else { $null })
                price        = $(if ($hasPrice) { [double]::Parse([string]$v.price, $INV) } else { $null })
                currency     = 'EUR'   # store currency; validated against row expectation
            }
        }
        $page++
    }
    Write-Info ("SharpEdge feed: {0} products across {1} page(s)" -f $index.Count, ($page - 1))
    return $index
}

function Get-SharpEdgeObservation {
    param($Row, $Index)
    $handle = Get-SharpEdgeHandle $Row.url
    if (-not $Index.ContainsKey($handle)) {
        return @{ ok = $false; reason = "handle not present in feed: $handle" }
    }
    $e = $Index[$handle]
    if (-not $e.hasAvail) { return @{ ok = $false; reason = "feed schema: 'available' missing for $handle" } }
    if (-not $e.hasPrice) { return @{ ok = $false; reason = "feed schema: 'price' missing for $handle" } }

    $avail = 'Esaurito'
    if ($e.available) { $avail = 'Disponibile' }
    return @{
        ok           = $true
        availability = $avail
        price        = $e.price
        currency     = 'EUR'
        identity     = $e.handle
    }
}

# ----------------------------------------------------------- source: hocho ---

function ConvertFrom-BCData {
    <# Extract the embedded BigCommerce product attributes. Pure: takes HTML text. #>
    param([string] $Html)

    $m = [regex]::Match($Html, 'var BCData = (\{.*?\});', 'Singleline')
    if (-not $m.Success) { return @{ ok = $false; reason = 'BCData block not found' } }

    $obj = $null
    try { $obj = $m.Groups[1].Value | ConvertFrom-Json } catch {
        return @{ ok = $false; reason = 'BCData present but not parseable' }
    }
    if (-not ($obj.PSObject.Properties.Name -contains 'product_attributes')) {
        return @{ ok = $false; reason = 'BCData without product_attributes' }
    }
    $pa = $obj.product_attributes

    $hasInstock = ($pa.PSObject.Properties.Name -contains 'instock') -and ($null -ne $pa.instock)
    if (-not $hasInstock) { return @{ ok = $false; reason = 'BCData without instock' } }

    $price = $null; $cur = $null
    try {
        $price = [double]$pa.price.with_tax.value
        $cur   = [string]$pa.price.with_tax.currency
    } catch {
        return @{ ok = $false; reason = 'BCData price not parseable' }
    }
    if ($null -eq $price -or -not $cur) { return @{ ok = $false; reason = 'BCData price/currency missing' } }

    $stock = $null
    if (($pa.PSObject.Properties.Name -contains 'stock') -and ($null -ne $pa.stock)) { $stock = [int]$pa.stock }

    $sku = ''
    if (($pa.PSObject.Properties.Name -contains 'sku') -and $pa.sku) { $sku = [string]$pa.sku }

    $avail = 'Esaurito'
    if ([bool]$pa.instock) { $avail = 'Disponibile' }

    return @{
        ok           = $true
        availability = $avail
        price        = $price
        currency     = $cur
        identity     = $sku
        stock        = $stock   # INTERNAL ONLY - never published
    }
}

function Get-HochoObservation {
    param($Row)
    $url = Get-HochoPlainUrl $Row.url
    try {
        $html = Invoke-SourceWithRetry -Url $url
    } catch {
        if ($_.Exception.Message -like 'GATEWAY REFUSED*') { throw }
        return @{ ok = $false; reason = "fetch failed: $($_.Exception.Message)" }
    }
    return ConvertFrom-BCData -Html $html
}

# ------------------------------------------------------------- comparison ----

function Compare-Observation {
    <#
        Pure classifier. Returns class:
          A  no change            B  price only
          C  availability only    BC both
          D  source failure       E  identity change
    #>
    param($Row, $Obs)

    if (-not $Obs.ok) { return @{ class = 'D'; reason = $Obs.reason } }

    # currency must match the row's expectation (P1-3) - the sanity band cannot see this
    if ($Obs.currency -ne $Row.valuta) {
        return @{ class = 'D'; reason = "currency mismatch: expected $($Row.valuta), observed $($Obs.currency)" }
    }

    $availChanged = ($Obs.availability -ne $Row.disponibilita)
    $priceChanged = ([math]::Abs([double]$Obs.price - [double]$Row.prezzo) -gt 0.0001)

    if ($priceChanged) {
        $ratio = [double]$Obs.price / [double]$Row.prezzo
        if ($ratio -lt $SANITY_LOW -or $ratio -gt $SANITY_HIGH) {
            return @{ class = 'E'; reason = ("price outside sanity band: {0} -> {1}" -f $Row.prezzo, $Obs.price) }
        }
    }

    if ($availChanged -and $priceChanged) { return @{ class = 'BC' } }
    if ($availChanged)                    { return @{ class = 'C' } }
    if ($priceChanged)                    { return @{ class = 'B' } }
    return @{ class = 'A' }
}

function Test-ObservationsAgree {
    <# Confirmation requires BOTH fields to agree across the two observations (G2). #>
    param($First, $Second)
    if (-not $Second.ok) { return $false }
    if ($First.availability -ne $Second.availability) { return $false }
    if ([math]::Abs([double]$First.price - [double]$Second.price) -gt 0.0001) { return $false }
    if ($First.currency -ne $Second.currency) { return $false }
    return $true
}

# ------------------------------------------------------------ json editing ---

function Set-ObservationField {
    <# Anchored, single-field edit. Never round-trips the document (P0-3). #>
    param(
        [Parameter(Mandatory=$true)][string] $Text,
        [Parameter(Mandatory=$true)][string] $Id,
        [Parameter(Mandatory=$true)][string] $Field,
        [Parameter(Mandatory=$true)][string] $RawValue
    )
    if ($MUTABLE_FIELDS -notcontains $Field) { throw "refusing to edit immutable field '$Field'" }

    $anchor = '"id": "' + $Id + '"'
    $start = $Text.IndexOf($anchor)
    if ($start -lt 0) { throw "anchor not found for id '$Id'" }

    $next = $Text.IndexOf('"id": "', $start + $anchor.Length)
    if ($next -lt 0) { $next = $Text.Length }

    $block = $Text.Substring($start, $next - $start)
    $rx = [regex]('"' + [regex]::Escape($Field) + '":\s*[^,\r\n]+')
    if (-not $rx.IsMatch($block)) { throw "field '$Field' not found in block '$Id'" }

    $replacement = '"' + $Field + '": ' + $RawValue
    $newBlock = $rx.Replace($block, { param($m) $replacement }, 1)

    return $Text.Substring(0, $start) + $newBlock + $Text.Substring($next)
}

function Format-Price { param([double] $P) return $P.ToString('0.00', $INV) }
function Format-Json  { param([string] $S) return '"' + $S + '"' }

function Assert-EditSafety {
    <# Every assertion required by the design must pass before anything is written. #>
    param([string] $Original, [string] $Updated, [int] $ExpectedRows = -1)

    if ($ExpectedRows -lt 0) { $ExpectedRows = $EXPECTED_ROWS }

    $a = $null; $b = $null
    try { $a = $Original | ConvertFrom-Json } catch { throw 'ASSERT: original JSON unparseable' }
    try { $b = $Updated  | ConvertFrom-Json } catch { throw 'ASSERT: edited JSON is not valid JSON' }

    $ra = @($a.osservazioni); $rb = @($b.osservazioni)
    if ($rb.Count -ne $ExpectedRows) { throw "ASSERT: expected $ExpectedRows observations, found $($rb.Count)" }
    if ($ra.Count -ne $rb.Count)      { throw 'ASSERT: observation count changed' }

    if (($a.meta | ConvertTo-Json -Depth 10 -Compress) -ne ($b.meta | ConvertTo-Json -Depth 10 -Compress)) {
        throw 'ASSERT: meta block changed'
    }

    $immutable = @('id','produttore','modello','tipo','acciaio','lunghezza_lama_mm',
                   'rivenditore','rivenditore_id','valuta','url')

    for ($i = 0; $i -lt $ra.Count; $i++) {
        if ($ra[$i].id -ne $rb[$i].id) { throw "ASSERT: row order/id changed at index $i" }
        foreach ($f in $immutable) {
            $va = $ra[$i].$f; $vb = $rb[$i].$f
            if ("$va" -ne "$vb") { throw "ASSERT: immutable field '$f' changed on $($ra[$i].id)" }
        }
        foreach ($p in $rb[$i].PSObject.Properties.Name) {
            if ($immutable -contains $p) { continue }
            if ($MUTABLE_FIELDS -contains $p) { continue }
            if ("$($ra[$i].$p)" -ne "$($rb[$i].$p)") {
                throw "ASSERT: unexpected field '$p' changed on $($ra[$i].id)"
            }
        }
    }
    return $true
}

function Write-ProductsFile {
    <# LF only, UTF-8 without BOM (P0-4). #>
    param([string] $Path, [string] $Text)
    $lf = $Text -replace "`r`n", "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $lf, $enc)
}

# ------------------------------------------------------------ live compare ---

function Get-SemanticFingerprint {
    param($Parsed)
    $rows = @($Parsed.osservazioni) | Sort-Object id
    $parts = foreach ($r in $rows) {
        '{0}|{1}|{2}|{3}' -f $r.id, $r.disponibilita, (Format-Price ([double]$r.prezzo)), $r.ultimo_controllo
    }
    return ($parts -join ';')
}

function Get-LiveProducts {
    param([switch] $Quiet)
    $cb = [Guid]::NewGuid().ToString('N')
    $url = "$SITE_BASE/$PRODUCTS_REL" + "?cb=$cb"   # our own Pages site; not a merchant URL
    $body = Invoke-Source -Url $url -NoCache
    return ($body | ConvertFrom-Json)
}

function Test-LiveInSync {
    param([string] $RepoText)
    try {
        $live = Get-LiveProducts
    } catch {
        Write-Warn "live site fetch failed: $($_.Exception.Message)"
        return $null   # unknown, not "out of sync"
    }
    $repoFp = Get-SemanticFingerprint ($RepoText | ConvertFrom-Json)
    $liveFp = Get-SemanticFingerprint $live
    return ($repoFp -eq $liveFp)
}

# ------------------------------------------------------------------- git -----

function Invoke-Git {
    param([string[]] $GitArgs, [switch] $AllowFail)
    $out = & git -C $RepoRoot @GitArgs 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFail) {
        throw "git $($GitArgs -join ' ') failed ($code): $out"
    }
    return @{ code = $code; out = ($out | Out-String).Trim() }
}

function Publish-Change {
    <# Path-limited commit + push. Aborts on rejection; never merges or rebases. #>
    param([int] $ChangedRows, [int] $ConfirmedChanges)

    Invoke-Git @('add', '--', $PRODUCTS_REL) | Out-Null

    $staged = Invoke-Git @('diff', '--cached', '--name-only')
    $names = @($staged.out -split "`n" | Where-Object { $_ -ne '' })
    if ($names.Count -eq 0) { Write-Info 'nothing staged - no commit'; return $null }
    foreach ($n in $names) {
        if ($n -ne $PRODUCTS_REL) { throw "REFUSING COMMIT: unexpected staged path '$n'" }
    }

    $msg = "chore(data): refresh $EXPECTED_ROWS rows - $ConfirmedChanges confirmed change(s)"
    Invoke-Git @('commit', '-m', $msg) | Out-Null

    $push = Invoke-Git @('push', 'origin', 'HEAD:main') -AllowFail
    if ($push.code -ne 0) {
        throw "PUSH REJECTED - aborting without merge or rebase. Next run re-evaluates from fresh HEAD. :: $($push.out)"
    }
    $sha = (Invoke-Git @('rev-parse', 'HEAD')).out
    Write-Info "committed and pushed $sha"
    return $sha
}

function Set-ActionOutput {
    param([string] $Name, [string] $Value)
    Write-Host "[out  ] $Name=$Value"
    if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" }
}

# ------------------------------------------------------------- self tests ----

function Invoke-SelfTest {
    $pass = 0; $fail = 0
    function T { param([string]$Name, [scriptblock]$Body)
        try {
            $r = & $Body
            if ($r) { Write-Host "  PASS  $Name"; $script:__p++ } else { Write-Host "  FAIL  $Name"; $script:__f++ }
        } catch { Write-Host "  FAIL  $Name :: $($_.Exception.Message)"; $script:__f++ }
    }
    $script:__p = 0; $script:__f = 0

    $sample = @'
{
  "meta": { "aggiornato_il": "2026-09-05", "rivenditori": [ { "id": "sharpedge" } ] },
  "osservazioni": [
    {
      "id": "se-01",
      "produttore": "Yu Kurosaki",
      "modello": "Senko Ei",
      "tipo": "Gyuto",
      "acciaio": "SG2",
      "lunghezza_lama_mm": 240,
      "rivenditore": "SharpEdge",
      "rivenditore_id": "sharpedge",
      "disponibilita": "Disponibile",
      "prezzo": 700.00,
      "valuta": "EUR",
      "ultimo_controllo": "2026-08-22T13:57:38Z",
      "url": "https://sharpedgeshop.com/products/aaa?sca_ref=12137326.VcuiEOuEwt"
    },
    {
      "id": "hk-01",
      "produttore": "Nigara Hamono",
      "modello": "STRIX",
      "tipo": "Gyuto",
      "acciaio": "SPG-STRIX",
      "lunghezza_lama_mm": 210,
      "rivenditore": "Hocho Knife",
      "rivenditore_id": "hocho",
      "disponibilita": "Esaurito",
      "prezzo": 548.99,
      "valuta": "USD",
      "ultimo_controllo": "2026-08-22T13:59:56Z",
      "url": "https://www.hocho-knife.com/nigara-strix-gyuto-210mm/?aff=361"
    }
  ]
}
'@
    $rows = ($sample | ConvertFrom-Json).osservazioni
    $se = $rows[0]; $hk = $rows[1]

    Write-Host "`n--- synthetic tests ---"

    # 1 no-change refresh
    T '1  no-change refresh -> class A' {
        (Compare-Observation $se @{ ok=$true; availability='Disponibile'; price=700.00; currency='EUR' }).class -eq 'A'
    }
    # 2 confirmed availability change
    T '2  availability change -> class C, agreeing pair confirms' {
        $o1 = @{ ok=$true; availability='Esaurito'; price=700.00; currency='EUR' }
        $o2 = @{ ok=$true; availability='Esaurito'; price=700.00; currency='EUR' }
        ((Compare-Observation $se $o1).class -eq 'C') -and (Test-ObservationsAgree $o1 $o2)
    }
    # 3 rejected / flickering change
    T '3  flicker -> second observation disagrees -> discard' {
        $o1 = @{ ok=$true; availability='Esaurito';    price=700.00; currency='EUR' }
        $o2 = @{ ok=$true; availability='Disponibile'; price=700.00; currency='EUR' }
        -not (Test-ObservationsAgree $o1 $o2)
    }
    # 4 confirmed price change
    T '4  price change -> class B' {
        (Compare-Observation $se @{ ok=$true; availability='Disponibile'; price=725.00; currency='EUR' }).class -eq 'B'
    }
    # 4b atomicity: price moved again during window -> discard
    T '4b price moved twice in window -> discard (G2 atomic)' {
        $o1 = @{ ok=$true; availability='Disponibile'; price=725.00; currency='EUR' }
        $o2 = @{ ok=$true; availability='Disponibile'; price=730.00; currency='EUR' }
        -not (Test-ObservationsAgree $o1 $o2)
    }
    # 5 missing SharpEdge available
    T '5  missing available -> class D, NEVER Esaurito' {
        $r = Compare-Observation $se @{ ok=$false; reason="feed schema: 'available' missing" }
        ($r.class -eq 'D')
    }
    T '5b feed parser flags missing available as not-ok' {
        $feed = '{"products":[{"handle":"aaa","title":"t","variants":[{"price":"700.00"}]}]}'
        $d = $feed | ConvertFrom-Json
        $v = @($d.products)[0].variants[0]
        $has = ($v.PSObject.Properties.Name -contains 'available') -and ($null -ne $v.available)
        (-not $has)
    }
    # 6 malformed Hocho BCData
    T '6  malformed BCData -> not ok, prior state preserved' {
        $r1 = ConvertFrom-BCData -Html '<html>no bcdata here</html>'
        $r2 = ConvertFrom-BCData -Html '<html>var BCData = {broken;</html>'
        (-not $r1.ok) -and (-not $r2.ok)
    }
    T '6b well-formed BCData parses instock/price/stock' {
        $html = 'x var BCData = {"product_attributes":{"sku":"S1","instock":true,"stock":2,"price":{"with_tax":{"value":563.99,"currency":"USD"}}}}; y'
        $r = ConvertFrom-BCData -Html $html
        $r.ok -and ($r.availability -eq 'Disponibile') -and ($r.price -eq 563.99) -and ($r.currency -eq 'USD') -and ($r.stock -eq 2)
    }
    # 7 affiliate URL rejected before request
    T '7  gateway refuses sca_ref before request' {
        $threw = $false
        try { Invoke-Source -Url 'https://sharpedgeshop.com/products/x?sca_ref=12137326.VcuiEOuEwt' } catch { $threw = ($_.Exception.Message -like 'GATEWAY REFUSED (pre-request)*') }
        $threw
    }
    T '7b gateway refuses aff=361 before request' {
        $threw = $false
        try { Invoke-Source -Url 'https://www.hocho-knife.com/x/?aff=361' } catch { $threw = ($_.Exception.Message -like 'GATEWAY REFUSED (pre-request)*') }
        $threw
    }
    T '7c stored affiliate URLs reduce to clean sources' {
        ((Get-SharpEdgeHandle $se.url) -eq 'aaa') -and
        ((Get-HochoPlainUrl $hk.url) -eq 'https://www.hocho-knife.com/nigara-strix-gyuto-210mm/') -and
        ((Get-HochoPlainUrl $hk.url) -notmatch $AFFILIATE_RX)
    }
    # 8 currency mismatch
    T '8  currency mismatch -> class D (band cannot see this)' {
        (Compare-Observation $hk @{ ok=$true; availability='Esaurito'; price=548.99; currency='EUR' }).class -eq 'D'
    }
    T '8b catastrophic parse -> class E via sanity band' {
        (Compare-Observation $se @{ ok=$true; availability='Disponibile'; price=70000.00; currency='EUR' }).class -eq 'E'
    }
    # 10 JSON field-change assertion
    T '10 anchored edit changes only permitted fields' {
        $t2 = Set-ObservationField -Text $sample -Id 'se-01' -Field 'disponibilita' -RawValue (Format-Json 'Esaurito')
        $t2 = Set-ObservationField -Text $t2 -Id 'se-01' -Field 'ultimo_controllo' -RawValue (Format-Json '2026-09-05T06:00:00Z')
        (Assert-EditSafety -Original $sample -Updated $t2 -ExpectedRows 2) -and
        (($t2 | ConvertFrom-Json).osservazioni[0].disponibilita -eq 'Esaurito') -and
        (($t2 | ConvertFrom-Json).osservazioni[1].disponibilita -eq 'Esaurito')
    }
    T '10b assertion rejects an immutable-field edit' {
        $bad = $sample -replace '"produttore": "Yu Kurosaki"', '"produttore": "Tampered"'
        $threw = $false
        try { Assert-EditSafety -Original $sample -Updated $bad -ExpectedRows 2 } catch { $threw = ($_.Exception.Message -like 'ASSERT: immutable field*') }
        $threw
    }
    T '10c refuses to edit a non-permitted field' {
        $threw = $false
        try { Set-ObservationField -Text $sample -Id 'se-01' -Field 'produttore' -RawValue '"X"' } catch { $threw = ($_.Exception.Message -like 'refusing to edit immutable field*') }
        $threw
    }
    T '10d assertion rejects a dropped row' {
        $threw = $false
        try { Assert-EditSafety -ExpectedRows 2 -Original $sample -Updated ($sample -replace '(?s),\s*\{\s*"id": "hk-01".*?\}\s*(\]\s*\}\s*)$', '$1') } catch { $threw = $true }
        $threw
    }
    # 11 LF / no whole-file churn
    T '11 edit preserves every untouched byte (no reserialization)' {
        $t2 = Set-ObservationField -Text $sample -Id 'se-01' -Field 'prezzo' -RawValue (Format-Price 725.00)
        $la = $sample -split "`n"; $lb = $t2 -split "`n"
        $diff = 0
        for ($i = 0; $i -lt $la.Count; $i++) { if ($la[$i] -ne $lb[$i]) { $diff++ } }
        ($la.Count -eq $lb.Count) -and ($diff -eq 1)
    }
    T '11b writer emits LF only' {
        $tmp = [IO.Path]::GetTempFileName()
        Write-ProductsFile -Path $tmp -Text "a`r`nb`r`n"
        $bytes = [IO.File]::ReadAllBytes($tmp)
        Remove-Item $tmp -Force
        ($bytes -notcontains 13)
    }
    # 12 repo/live mismatch -> deploy needed
    T '12 semantic fingerprint detects repo/live mismatch' {
        $live = $sample | ConvertFrom-Json
        $repo = ($sample -replace '"disponibilita": "Disponibile"', '"disponibilita": "Esaurito"') | ConvertFrom-Json
        (Get-SemanticFingerprint $live) -ne (Get-SemanticFingerprint $repo)
    }
    T '12b identical data -> in sync' {
        (Get-SemanticFingerprint ($sample | ConvertFrom-Json)) -eq (Get-SemanticFingerprint ($sample | ConvertFrom-Json))
    }
    # 13 timestamp semantics
    T '13 timestamp advances only with an agreeing observation' {
        # agreeing -> advance ; contradictory single -> do not advance
        $agree = (Compare-Observation $se @{ ok=$true; availability='Disponibile'; price=700.00; currency='EUR' }).class -eq 'A'
        $contra = (Compare-Observation $se @{ ok=$true; availability='Esaurito'; price=700.00; currency='EUR' }).class -eq 'C'
        $fail  = (Compare-Observation $se @{ ok=$false; reason='timeout' }).class -eq 'D'
        $agree -and $contra -and $fail
    }

    Write-Host "`n--- results: $script:__p passed, $script:__f failed ---"
    if ($script:__f -gt 0) { exit 1 }
    Write-Host 'ALL SYNTHETIC TESTS PASSED'
    exit 0
}

# ---------------------------------------------------------------- main run ---

if ($Mode -eq 'selftest') { Invoke-SelfTest }

$productsPath = Join-Path $RepoRoot $PRODUCTS_REL
if (-not (Test-Path $productsPath)) { throw "products.json not found at $productsPath" }
$repoText = [IO.File]::ReadAllText($productsPath)
$repoData = $repoText | ConvertFrom-Json
$rows = @($repoData.osservazioni)
if ($rows.Count -ne $EXPECTED_ROWS) { throw "expected $EXPECTED_ROWS observations, found $($rows.Count)" }

Write-Info "mode=$Mode rows=$($rows.Count) forceDeploy=$([bool]$ForceDeploy)"

# ---- verify mode: live must match repo ----
if ($Mode -eq 'verify') {
    $deadline = (Get-Date).AddMinutes(5)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        $sync = Test-LiveInSync -RepoText $repoText
        if ($sync -eq $true) { $ok = $true; break }
        Start-Sleep -Seconds 20
    }
    if (-not $ok) { throw 'VERIFY FAILED: live site does not match repository data after deployment' }
    Write-Info 'VERIFY OK: live site matches repository data'
    exit 0
}

# ---- live/repo sync check (start of run) ----
$inSync = Test-LiveInSync -RepoText $repoText
$liveOutOfSync = ($inSync -eq $false)
if ($liveOutOfSync) { Write-Warn 'live site is OUT OF SYNC with repository - deployment recovery required' }

# ---- fetch all sources ----
$feed = $null
try { $feed = Get-SharpEdgeCatalog } catch {
    if ($_.Exception.Message -like 'GATEWAY REFUSED*') { throw }
    Write-Warn "SharpEdge feed unavailable: $($_.Exception.Message)"
}

$observations = @{}
foreach ($r in $rows) {
    if ($r.rivenditore_id -eq 'sharpedge') {
        if ($null -eq $feed) { $observations[$r.id] = @{ ok = $false; reason = 'feed unavailable' } }
        else { $observations[$r.id] = Get-SharpEdgeObservation -Row $r -Index $feed }
    } else {
        $observations[$r.id] = Get-HochoObservation -Row $r
    }
}

# ---- classify ----
$candidates = @()
$agreeing   = @()
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

foreach ($r in $rows) {
    $obs = $observations[$r.id]
    $cls = Compare-Observation -Row $r -Obs $obs
    switch ($cls.class) {
        'A'  { $agreeing += [pscustomobject]@{ row = $r; obs = $obs } }
        'D'  { Write-Warn "$($r.id): source failure - $($cls.reason) (previous state preserved)" }
        'E'  { Add-Escalation "$($r.id): identity/sanity escalation - $($cls.reason)" }
        default { $candidates += [pscustomobject]@{ row = $r; first = $obs; class = $cls.class } }
    }
}

Write-Info ("classified: {0} agreeing, {1} candidate(s), {2} warning(s), {3} escalation(s)" -f `
    $agreeing.Count, $candidates.Count, $script:Warnings.Count, $script:Escalations.Count)

# ---- staleness check (replaces a persistent failure counter) ----
foreach ($r in $rows) {
    $obs = $observations[$r.id]
    if ($obs.ok) { continue }
    $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse($r.ultimo_controllo, $INV, [Globalization.DateTimeStyles]::AdjustToUniversal)).TotalHours
    if ($age -gt $STALE_HOURS) {
        Add-Escalation ("{0}: unchecked for {1:N1}h (> {2}h) - sustained source failure" -f $r.id, $age, $STALE_HOURS)
    }
}

# ---- confirmation pass (in-run, no persistent candidate state) ----
$confirmed = @()
if ($candidates.Count -gt 0) {
    Write-Info ("waiting {0}s before confirmation re-check of {1} row(s)" -f $ConfirmWaitSeconds, $candidates.Count)
    Start-Sleep -Seconds $ConfirmWaitSeconds

    $feed2 = $null
    if ($candidates | Where-Object { $_.row.rivenditore_id -eq 'sharpedge' }) {
        try { $feed2 = Get-SharpEdgeCatalog } catch {
            if ($_.Exception.Message -like 'GATEWAY REFUSED*') { throw }
            Write-Warn "confirmation feed unavailable: $($_.Exception.Message)"
        }
    }

    foreach ($c in $candidates) {
        $second = $null
        if ($c.row.rivenditore_id -eq 'sharpedge') {
            if ($null -eq $feed2) { $second = @{ ok = $false; reason = 'feed unavailable' } }
            else { $second = Get-SharpEdgeObservation -Row $c.row -Index $feed2 }
        } else {
            $second = Get-HochoObservation -Row $c.row
        }

        if (Test-ObservationsAgree -First $c.first -Second $second) {
            $confirmed += [pscustomobject]@{ row = $c.row; obs = $second }
            Write-Info "$($c.row.id): CONFIRMED $($c.row.disponibilita)/$($c.row.prezzo) -> $($second.availability)/$($second.price)"
        } else {
            # Second observation may have returned to the published state: still a valid check.
            if ($second.ok -and $second.availability -eq $c.row.disponibilita -and
                ([math]::Abs([double]$second.price - [double]$c.row.prezzo) -le 0.0001)) {
                $agreeing += [pscustomobject]@{ row = $c.row; obs = $second }
                Write-Info "$($c.row.id): candidate discarded - second observation matches published state"
            } else {
                Write-Warn "$($c.row.id): candidate discarded - observations disagree (state preserved)"
            }
        }
    }
}

# ---- build the proposed edit ----
$updated = $repoText
$changedRows = 0
foreach ($a in $agreeing) {
    $updated = Set-ObservationField -Text $updated -Id $a.row.id -Field 'ultimo_controllo' -RawValue (Format-Json $now)
}
foreach ($c in $confirmed) {
    $updated = Set-ObservationField -Text $updated -Id $c.row.id -Field 'disponibilita'   -RawValue (Format-Json $c.obs.availability)
    $updated = Set-ObservationField -Text $updated -Id $c.row.id -Field 'prezzo'          -RawValue (Format-Price ([double]$c.obs.price))
    $updated = Set-ObservationField -Text $updated -Id $c.row.id -Field 'ultimo_controllo' -RawValue (Format-Json $now)
    $changedRows++
}

$dataChanged = ($updated -ne $repoText)
if ($dataChanged) { Assert-EditSafety -Original $repoText -Updated $updated | Out-Null }

Write-Info ("data change proposed: {0} (confirmed row changes: {1})" -f $dataChanged, $changedRows)

# ---- write / commit / deploy decision ----
$deployRef = ''
$pushedSha = $null

if ($Mode -eq 'write') {
    if ($dataChanged) {
        Write-ProductsFile -Path $productsPath -Text $updated
        $pushedSha = Publish-Change -ChangedRows $changedRows -ConfirmedChanges $confirmed.Count
    } else {
        Write-Info 'no data change - nothing committed'
    }
} else {
    Write-Info 'DRY-RUN: no file written, no commit, no push'
}

if ($pushedSha) {
    $deployRef = $pushedSha
} else {
    Invoke-Git @('fetch', 'origin', 'main', '--quiet') -AllowFail | Out-Null
    $deployRef = (Invoke-Git @('rev-parse', 'origin/main')).out
}

$deployNeeded = $false
if ($Mode -eq 'write' -and $dataChanged) { $deployNeeded = $true }
if ($liveOutOfSync)                      { $deployNeeded = $true }
if ($ForceDeploy)                        { $deployNeeded = $true }

Set-ActionOutput 'deploy_needed' $(if ($deployNeeded) { 'true' } else { 'false' })
Set-ActionOutput 'deploy_ref'    $deployRef
Set-ActionOutput 'data_changed'  $(if ($dataChanged) { 'true' } else { 'false' })

Write-Info ("gateway calls={0} refusals={1}" -f $script:GatewayCalls, $script:GatewayRefusals)

if ($script:Escalations.Count -gt 0) {
    Write-Host "`nESCALATIONS (workflow will fail):"
    $script:Escalations | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Info 'run complete'
exit 0
