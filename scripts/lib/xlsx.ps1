# =======================================================================================
# Minimal .xlsx writer - builds the OpenXML package directly, no Excel and no modules.
#
# WHY THIS EXISTS. export-distribution-xlsx.ps1 drives Excel over COM, which works for a few
# small sheets. It does not survive a workbook of this size: building the disqualification
# workbook (10 sheets, ~9,400 rows) threw OutOfMemoryException at the same sheet every run,
# with screen updating off, manual calculation, chunked writes and header-only AutoFilter.
# Writing the package ourselves has no such ceiling and is deterministic.
#
# Strings are written INLINE rather than through sharedStrings.xml. That makes the file
# slightly larger and removes a whole class of index-mismatch bug.
#
# ASCII-only source (CLAUDE.md hard rule 6). Cell VALUES may be any Unicode - they are written
# as UTF-8 bytes into the archive, which is where the Devanagari in these transcripts lives.
# =======================================================================================

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

function ConvertTo-XlsxColumnName {
    param([Parameter(Mandatory)][int]$Index)   # 1-based
    $s = ""
    $i = $Index
    while ($i -gt 0) {
        $m = ($i - 1) % 26
        $s = [char](65 + $m) + $s
        $i = [int](($i - $m) / 26)
    }
    return $s
}

function Protect-XlsxText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return "" }
    # Strip control characters: XML 1.0 forbids them and Excel refuses to open the file.
    $clean = [regex]::Replace($Text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    return $clean.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
}

function New-XlsxWorkbook {
    <#
      Sheets: array of hashtables @{ Name = 'Sheet1'; Headers = @(...); Rows = @(@(...), ...) }
      Numeric cells are detected by type, so pass real ints/doubles where you want them numeric.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Sheets,
        [Parameter(Mandatory)][string]$Path
    )

    $utf8 = New-Object Text.UTF8Encoding($false)
    if (Test-Path $Path) { Remove-Item $Path -Force }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    $zip = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Create)

    function Add-Entry([string]$name, [string]$content) {
        $e = $zip.CreateEntry($name, [IO.Compression.CompressionLevel]::Optimal)
        $s = $e.Open()
        $b = $utf8.GetBytes($content)
        $s.Write($b, 0, $b.Length)
        $s.Dispose()
    }

    try {
        $n = $Sheets.Count

        # ---- [Content_Types].xml ----
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        [void]$sb.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
        [void]$sb.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
        [void]$sb.Append('<Default Extension="xml" ContentType="application/xml"/>')
        [void]$sb.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
        [void]$sb.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
        for ($i = 1; $i -le $n; $i++) {
            [void]$sb.Append('<Override PartName="/xl/worksheets/sheet' + $i + '.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>')
        }
        [void]$sb.Append('</Types>')
        Add-Entry '[Content_Types].xml' $sb.ToString()

        # ---- _rels/.rels ----
        Add-Entry '_rels/.rels' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
            '</Relationships>')

        # ---- xl/workbook.xml ----
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        [void]$sb.Append('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>')
        for ($i = 1; $i -le $n; $i++) {
            # Excel sheet names: max 31 chars, and : \ / ? * [ ] are illegal.
            $nm = [regex]::Replace([string]$Sheets[$i-1].Name, '[:\\/\?\*\[\]]', '-')
            if ($nm.Length -gt 31) { $nm = $nm.Substring(0, 31) }
            [void]$sb.Append('<sheet name="' + (Protect-XlsxText $nm) + '" sheetId="' + $i + '" r:id="rId' + $i + '"/>')
        }
        [void]$sb.Append('</sheets></workbook>')
        Add-Entry 'xl/workbook.xml' $sb.ToString()

        # ---- xl/_rels/workbook.xml.rels ----
        $sb = New-Object Text.StringBuilder
        [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
        [void]$sb.Append('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
        for ($i = 1; $i -le $n; $i++) {
            [void]$sb.Append('<Relationship Id="rId' + $i + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet' + $i + '.xml"/>')
        }
        [void]$sb.Append('<Relationship Id="rId' + ($n + 1) + '" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>')
        [void]$sb.Append('</Relationships>')
        Add-Entry 'xl/_rels/workbook.xml.rels' $sb.ToString()

        # ---- xl/styles.xml : style 0 = normal, style 1 = bold on grey (the header row) ----
        Add-Entry 'xl/styles.xml' ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
            '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
            '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>' +
            '<font><b/><sz val="11"/><name val="Calibri"/></font></fonts>' +
            '<fills count="3"><fill><patternFill patternType="none"/></fill>' +
            '<fill><patternFill patternType="gray125"/></fill>' +
            '<fill><patternFill patternType="solid"><fgColor rgb="FFD9D9D9"/><bgColor indexed="64"/></patternFill></fill></fills>' +
            '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
            '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
            '<cellXfs count="2">' +
            '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
            '<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>' +
            '</cellXfs></styleSheet>')

        # ---- worksheets ----
        for ($si = 0; $si -lt $n; $si++) {
            $spec    = $Sheets[$si]
            $headers = @($spec.Headers)
            $rows    = @($spec.Rows)
            $cols    = $headers.Count
            $lastCol = ConvertTo-XlsxColumnName $cols
            $lastRow = $rows.Count + 1

            $w = New-Object Text.StringBuilder (1024 * 64)
            [void]$w.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
            [void]$w.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
            [void]$w.Append('<sheetViews><sheetView workbookViewId="0">')
            [void]$w.Append('<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>')
            [void]$w.Append('</sheetView></sheetViews>')

            if ($spec.ColWidths) {
                [void]$w.Append('<cols>')
                for ($c = 1; $c -le $cols; $c++) {
                    $wd = if ($c -le $spec.ColWidths.Count) { $spec.ColWidths[$c-1] } else { 16 }
                    [void]$w.Append('<col min="' + $c + '" max="' + $c + '" width="' + $wd + '" customWidth="1"/>')
                }
                [void]$w.Append('</cols>')
            }

            [void]$w.Append('<sheetData>')
            # header
            [void]$w.Append('<row r="1">')
            for ($c = 1; $c -le $cols; $c++) {
                $ref = (ConvertTo-XlsxColumnName $c) + '1'
                [void]$w.Append('<c r="' + $ref + '" s="1" t="inlineStr"><is><t xml:space="preserve">' +
                    (Protect-XlsxText ([string]$headers[$c-1])) + '</t></is></c>')
            }
            [void]$w.Append('</row>')
            # body
            for ($r = 0; $r -lt $rows.Count; $r++) {
                $row = @($rows[$r])
                $rn = $r + 2
                [void]$w.Append('<row r="' + $rn + '">')
                for ($c = 1; $c -le $cols; $c++) {
                    $v = if ($c -le $row.Count) { $row[$c-1] } else { $null }
                    if ($null -eq $v -or "$v" -eq '') { continue }
                    $ref = (ConvertTo-XlsxColumnName $c) + $rn
                    if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [decimal] -or $v -is [single]) {
                        [void]$w.Append('<c r="' + $ref + '"><v>' + ([string]$v) + '</v></c>')
                    } else {
                        [void]$w.Append('<c r="' + $ref + '" t="inlineStr"><is><t xml:space="preserve">' +
                            (Protect-XlsxText ([string]$v)) + '</t></is></c>')
                    }
                }
                [void]$w.Append('</row>')
            }
            [void]$w.Append('</sheetData>')
            if ($lastRow -gt 1) {
                [void]$w.Append('<autoFilter ref="A1:' + $lastCol + $lastRow + '"/>')
            }
            [void]$w.Append('</worksheet>')
            Add-Entry ('xl/worksheets/sheet' + ($si + 1) + '.xml') $w.ToString()
        }
    } finally {
        $zip.Dispose()
        $fs.Dispose()
    }
    return $Path
}
