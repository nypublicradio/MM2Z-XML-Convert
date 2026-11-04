[CmdletBinding()]
# Configure the source and destination folders, logging, and polling interval.
param(
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$InputDirectory = '\\nynas01\Zetta\Data\Autoload\MM_to_Z\NewSounds\1',

    [string]$OutputDirectory = '\\nynas01\Zetta\Data\Autoload\MM_to_Z\NewSounds\2',

    [string]$LogDirectory = 'C:\logging',

    [ValidateRange(1, 3600)]
    [int]$PollIntervalSeconds = 60
)

# Treat operational errors as failures and identify fields that may contain semicolon-separated values.
$ErrorActionPreference = 'Stop'
$metadataTags = @('Composer', 'Conductor', 'Artist', 'Orchestra', 'Musician')
$logPath = Join-Path $LogDirectory 'XmlConversion.log'

# Append a timestamped status line for each file handled by the watcher.
function Write-ConversionLog {
    param(
        [string]$Status,
        [string]$FileName,
        [string]$Details = ''
    )

    $entry = '{0} [{1}] {2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Status, $FileName, $Details
    try {
        Add-Content -LiteralPath $logPath -Value $entry -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write to log '$logPath': $($_.Exception.Message)"
    }
}

# Create the destination and logging folders when they do not already exist.
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $LogDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

# Track file versions so each one is stable for a poll before conversion and is not converted repeatedly.
$observedSignatures = @{}
$processedSignatures = @{}
Write-Host "Watching '$InputDirectory' every $PollIntervalSeconds second(s). Press Ctrl+C to stop."

# Keep checking the input folder until the script is stopped with Ctrl+C.
while ($true) {
    $files = @(Get-ChildItem -LiteralPath $InputDirectory -Filter '*.xml' -File)

    foreach ($file in $files) {
        # Use size and last-write time to detect files still being copied or edited.
        $signature = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
        if ($processedSignatures[$file.FullName] -eq $signature) {
            continue
        }
        if ($observedSignatures[$file.FullName] -ne $signature) {
            $observedSignatures[$file.FullName] = $signature
            continue
        }

        # Retain the input if its destination already exists; never overwrite existing output.
        $destination = Join-Path $OutputDirectory $file.Name
        if (Test-Path -LiteralPath $destination) {
            $conflictDetails = "Output already exists at '$destination'; input retained."
            Write-Warning "Conflict for '$($file.Name)': $conflictDetails"
            Write-ConversionLog -Status 'OUTPUT_CONFLICT' -FileName $file.Name -Details $conflictDetails
            continue
        }

        try {
            # Load the source XML and verify it has the expected Music Master root element.
            $document = [System.Xml.XmlDocument]::new()
            $document.PreserveWhitespace = $false
            $document.XmlResolver = $null
            $document.Load($file.FullName)

            $root = $document.DocumentElement
            if ($null -eq $root -or $root.LocalName -ne 'XMLDAT') {
                throw 'Root element must be XMLDAT.'
            }

            $songNodes = @($root.SelectNodes('./Song'))
            if ($songNodes.Count -eq 0) {
                Write-Warning "Skipped '$($file.Name)': no direct Song element found."
                Write-ConversionLog -Status 'SKIPPED' -FileName $file.Name -Details 'No direct Song element found.'
                $processedSignatures[$file.FullName] = $signature
                continue
            }

            # Split listed metadata values into repeated elements, then move Song contents under XMLDAT.
            $preservedElements = @()
            foreach ($song in $songNodes) {
                $mapsNonMusicToType = @($song.SelectNodes('./Non-Music') | Where-Object { $_.InnerText.Trim() -eq '0' }).Count -gt 0
                foreach ($element in @($song.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })) {
                    $willBeSplit = $element.LocalName -in $metadataTags -and $element.InnerText.Contains(';')
                    $willBeMapped = $element.LocalName -eq 'Non-Music' -and $element.InnerText.Trim() -eq '0'
                    $willBeUpdatedType = $mapsNonMusicToType -and $element.LocalName -eq 'Type'
                    if (-not ($willBeSplit -or $willBeMapped -or $willBeUpdatedType)) {
                        $preservedElements += [pscustomobject]@{
                            Element = $element
                            OriginalXml = $element.OuterXml
                        }
                    }
                }

                # Convert Music Master Non-Music value 0 to the Zetta Type classification.
                foreach ($nonMusic in @($song.SelectNodes('./Non-Music'))) {
                    $mappedTag = $null
                    switch ($nonMusic.InnerText.Trim()) {
                        '0' {
                            $mappedTag = 'Type'
                            $mappedValue = '2'
                        }
                        default {
                            Write-Warning "Unrecognized Non-Music value '$($nonMusic.InnerText)' in '$($file.Name)'; leaving it unchanged."
                        }
                    }
                    if ($null -eq $mappedTag) {
                        continue
                    }

                    $mappedElement = $song.SelectSingleNode("./$mappedTag")
                    if ($null -eq $mappedElement) {
                        $mappedElement = $document.CreateElement($mappedTag)
                        [void]$song.InsertBefore($mappedElement, $nonMusic)
                    }
                    $mappedElement.InnerText = $mappedValue
                    [void]$song.RemoveChild($nonMusic)
                }

                $elements = @($song.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })
                foreach ($element in $elements) {
                    if ($element.LocalName -in $metadataTags -and $element.InnerText.Contains(';')) {
                        $parts = @($element.InnerText -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
                        foreach ($part in $parts) {
                            $replacement = [System.Xml.XmlElement]$element.CloneNode($false)
                            $replacement.InnerText = $part
                            [void]$element.ParentNode.InsertBefore($replacement, $element)
                        }
                        [void]$element.ParentNode.RemoveChild($element)
                    }
                }

                while ($song.FirstChild) {
                    [void]$root.InsertBefore($song.FirstChild, $song)
                }
                [void]$root.RemoveChild($song)
            }

            # Abort rather than write output if any untouched source element changed or was lost.
            foreach ($preserved in $preservedElements) {
                if (-not [object]::ReferenceEquals($preserved.Element.ParentNode, $root) -or $preserved.Element.OuterXml -cne $preserved.OriginalXml) {
                    throw "Preserved element <$($preserved.Element.LocalName)> changed during conversion."
                }
            }

            # Save formatted UTF-8 XML to the destination folder.
            $settings = [System.Xml.XmlWriterSettings]::new()
            $settings.Encoding = [System.Text.UTF8Encoding]::new($false)
            $settings.Indent = $true
            $settings.IndentChars = '  '
            $settings.NewLineChars = "`r`n"

            $outputStream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $writer = [System.Xml.XmlWriter]::Create($outputStream, $settings)
                try {
                    $document.Save($writer)
                }
                finally {
                    $writer.Dispose()
                }
            }
            finally {
                $outputStream.Dispose()
            }

            # Reopen the saved file and verify every untouched source element survived serialization.
            try {
                $writtenDocument = [System.Xml.XmlDocument]::new()
                $writtenDocument.XmlResolver = $null
                $writtenDocument.Load($destination)
                $expectedElements = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
                foreach ($preserved in $preservedElements) {
                    if (-not $expectedElements.ContainsKey($preserved.OriginalXml)) {
                        $expectedElements[$preserved.OriginalXml] = 0
                    }
                    $expectedElements[$preserved.OriginalXml]++
                }

                $writtenElements = @($writtenDocument.DocumentElement.ChildNodes | Where-Object { $_ -is [System.Xml.XmlElement] })
                foreach ($expectedXml in $expectedElements.Keys) {
                    $writtenCount = @($writtenElements | Where-Object { $_.OuterXml -ceq $expectedXml }).Count
                    if ($writtenCount -lt $expectedElements[$expectedXml]) {
                        throw "Saved output is missing or changed an untouched XML element: $expectedXml"
                    }
                }
            }
            catch {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
                throw
            }

            Write-Host "Converted '$($file.Name)' to '$destination'."
            Write-ConversionLog -Status 'CONVERTED' -FileName $file.Name -Details "Output: $destination"

            # Delete the original only after writing and validating its converted output.
            try {
                Remove-Item -LiteralPath $file.FullName -Force
                Write-ConversionLog -Status 'INPUT_DELETED' -FileName $file.Name
            }
            catch {
                Write-Warning "Converted '$($file.Name)', but failed to delete the input: $($_.Exception.Message)"
                Write-ConversionLog -Status 'INPUT_DELETE_FAILED' -FileName $file.Name -Details $_.Exception.Message
            }

            # Mark this file version complete so later polls do not process it again.
            $processedSignatures[$file.FullName] = $signature
        }
        catch {
            # Leave failed files unmarked so a later poll can retry them.
            Write-Warning "Failed to convert '$($file.Name)': $($_.Exception.Message)"
            Write-ConversionLog -Status 'FAILED' -FileName $file.Name -Details $_.Exception.Message
        }
    }

    # Pause between scans to limit repeated directory checks.
    Start-Sleep -Seconds $PollIntervalSeconds
}

# SIG # Begin signature block
# MIIl5AYJKoZIhvcNAQcCoIIl1TCCJdECAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUBH0RZ4bVJoAr1mZDLJGh+6ha
# xlGggiAuMIIFjTCCBHWgAwIBAgIQDpsYjvnQLefv21DiCEAYWjANBgkqhkiG9w0B
# AQwFADBlMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYD
# VQQLExB3d3cuZGlnaWNlcnQuY29tMSQwIgYDVQQDExtEaWdpQ2VydCBBc3N1cmVk
# IElEIFJvb3QgQ0EwHhcNMjIwODAxMDAwMDAwWhcNMzExMTA5MjM1OTU5WjBiMQsw
# CQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNlcnQgSW5jMRkwFwYDVQQLExB3d3cu
# ZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdpQ2VydCBUcnVzdGVkIFJvb3QgRzQw
# ggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQC/5pBzaN675F1KPDAiMGkz
# 7MKnJS7JIT3yithZwuEppz1Yq3aaza57G4QNxDAf8xukOBbrVsaXbR2rsnnyyhHS
# 5F/WBTxSD1Ifxp4VpX6+n6lXFllVcq9ok3DCsrp1mWpzMpTREEQQLt+C8weE5nQ7
# bXHiLQwb7iDVySAdYyktzuxeTsiT+CFhmzTrBcZe7FsavOvJz82sNEBfsXpm7nfI
# SKhmV1efVFiODCu3T6cw2Vbuyntd463JT17lNecxy9qTXtyOj4DatpGYQJB5w3jH
# trHEtWoYOAMQjdjUN6QuBX2I9YI+EJFwq1WCQTLX2wRzKm6RAXwhTNS8rhsDdV14
# Ztk6MUSaM0C/CNdaSaTC5qmgZ92kJ7yhTzm1EVgX9yRcRo9k98FpiHaYdj1ZXUJ2
# h4mXaXpI8OCiEhtmmnTK3kse5w5jrubU75KSOp493ADkRSWJtppEGSt+wJS00mFt
# 6zPZxd9LBADMfRyVw4/3IbKyEbe7f/LVjHAsQWCqsWMYRJUadmJ+9oCw++hkpjPR
# iQfhvbfmQ6QYuKZ3AeEPlAwhHbJUKSWJbOUOUlFHdL4mrLZBdd56rF+NP8m800ER
# ElvlEFDrMcXKchYiCd98THU/Y+whX8QgUWtvsauGi0/C1kVfnSD8oR7FwI+isX4K
# Jpn15GkvmB0t9dmpsh3lGwIDAQABo4IBOjCCATYwDwYDVR0TAQH/BAUwAwEB/zAd
# BgNVHQ4EFgQU7NfjgtJxXWRM3y5nP+e6mK4cD08wHwYDVR0jBBgwFoAUReuir/SS
# y4IxLVGLp6chnfNtyA8wDgYDVR0PAQH/BAQDAgGGMHkGCCsGAQUFBwEBBG0wazAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAC
# hjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURS
# b290Q0EuY3J0MEUGA1UdHwQ+MDwwOqA4oDaGNGh0dHA6Ly9jcmwzLmRpZ2ljZXJ0
# LmNvbS9EaWdpQ2VydEFzc3VyZWRJRFJvb3RDQS5jcmwwEQYDVR0gBAowCDAGBgRV
# HSAAMA0GCSqGSIb3DQEBDAUAA4IBAQBwoL9DXFXnOF+go3QbPbYW1/e/Vwe9mqyh
# hyzshV6pGrsi+IcaaVQi7aSId229GhT0E0p6Ly23OO/0/4C5+KH38nLeJLxSA8hO
# 0Cre+i1Wz/n096wwepqLsl7Uz9FDRJtDIeuWcqFItJnLnU+nBgMTdydE1Od/6Fmo
# 8L8vC6bp8jQ87PcDx4eo0kxAGTVGamlUsLihVo7spNU96LHc/RzY9HdaXFSMb++h
# UD38dglohJ9vytsgjTVgHAIDyyCwrFigDkBjxZgiwbJZ9VVrzyerbHbObyMt9H5x
# aiNrIv8SuFQtJ37YOtnwtoeW/VvRXKwYw02fc7cBqZ9Xql4o4rmUMIIGTjCCBDag
# AwIBAgITQwAAAAgRZhSJ24Z1nwAAAAAACDANBgkqhkiG9w0BAQ0FADAoMSYwJAYD
# VQQDEx1OZXcgWW9yayBQdWJsaWMgUmFkaW8gUm9vdCBHMTAeFw0yNjAxMjcxOTMx
# NDJaFw0zNjAxMjcxOTQxNDJaMD4xEzARBgoJkiaJk/IsZAEZFgNPUkcxFDASBgoJ
# kiaJk/IsZAEZFgRXTllDMREwDwYDVQQDEwhOWVBSIFNHMjCCAiIwDQYJKoZIhvcN
# AQEBBQADggIPADCCAgoCggIBAKG7mN7uQ7/mh8O6r4SXur5C9AQwBZVYRuhG7iRC
# KBLvPG7fjv/tzcZYevvmCpFvexxx7nHFA2TYeK2tCA9wSWGRch2tj7elEuGF9Oc4
# 7TbQy1P9qebg3Ge99Z5TXYVSuoPXPtQLdh0jKr/Vf+AYChdhaEMfmUdAcKSjTyiF
# d9so8vsdcPnt86ymR+2qmBcZOIPSyjx7MJjzvRb5CSG07DNMqlSroH2AeFDCkRLx
# ya5QIjzbf2FVarhYvvzJdqFySsz61KPOqZl7gkvxint+3eahlmulvxG0bdK8HYgp
# 8T7zHeG425eGCYih0uXJDT8b6beyB0CwLbUbc32lcGrS0pbVbbzJpE6/gCsCjfat
# cj5Txw4nk/XPZzot7RZfT9msLHWqBkrWMp701kO4t1sx5jhkG9ZuV3P6E3IPcHVz
# BHLmfL9W+BMxzfqppvFl+ZfHJD7HsOqWCv3gQUmCjk7auGR+cVGiTPgH3WomIk4r
# OyCHN59Ifv8V6aFVssXrYx5VIAtr7FtCkGxpftQScBqlF9yIX0ZQuCatGfgovKVs
# yQBEf0k3iuzD02ZioOtl+/dMxyx3MkfBdOJtrvmq6fEcVcrUDpVtPhxXOlcFtaWC
# amA/nQnyPEg9iLG/qB+wB1SgvXFMYKS0ijM9Iw1e4G/dYY6rlEU/TPQ5BKWmoEiM
# qn+9AgMBAAGjggFZMIIBVTAQBgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUOXt9
# cP0BKfUOl2dbsSs0lO3i70owGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYD
# VR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAUv6z6/G6Kkzj0
# UUu2HiJbW3NLkRAwWwYDVR0fBFQwUjBQoE6gTIZKaHR0cDovL3BraS53bnljLm9y
# Zy9DZXJ0RW5yb2xsL05ldyUyMFlvcmslMjBQdWJsaWMlMjBSYWRpbyUyMFJvb3Ql
# MjBHMS5jcmwwawYIKwYBBQUHAQEEXzBdMFsGCCsGAQUFBzAChk9maWxlOi8vLy9O
# WVBLSTAxL0NlcnRFbnJvbGwvTllQS0kwMV9OZXclMjBZb3JrJTIwUHVibGljJTIw
# UmFkaW8lMjBSb290JTIwRzEuY3J0MA0GCSqGSIb3DQEBDQUAA4ICAQBkaJbRNK4Y
# hQ1EaCvxbl7OmlIa0N/iJ0my6aMjLXQZlG7K6q0nkLrHIeNF/CtGDIzUS79OP49Z
# HKHtQR8KtCqadHJyLvp7G5C1pt+1XghGYPVSFyWWBEtnrJ7757WOEkgcDzq3R9Ac
# 9TbwlI7tqsCjQ09lGlbPmqmzWvnjho8fz9ba0pXhYdBO4uoJ+ICuIDX+N8pLpwan
# +pDsy78wlfBokL2D0QqwR1XKWDWKfOWnOWNZ1hGY75yl61ojNDDmoPdCPBAhAJ9g
# gTkhJvr/9iny5schjsXxgrWhgpZQaNLWCmIaXGcC3ubyj7Z6r1ANdNDm3/VgCB/7
# CgPx7VRA4vRsRHSU4fol2hwx9ttfQLqsLpu9+ZepgbZRyhRwV++VEndiW923rpg8
# 7WmI7h2JQPP+aIxwCkT1c/6g9uCi2gm1/FJAwShNWqeI8Ce/BEGyQDnDhZhwP3R8
# ewSWgNpqCaWav4cdbtYy9aAhcKb/1cuvAUndl/EgGnApJRlLLF6ZdeEGo4jdMxS7
# 4wUVTTosuVuje5dZwK92FEaZ9Dy7OwD8img8058B8SGkfkytjkUSPPfN7evMK5u5
# yM4PykgPL6LozkQLcnOn2ib3jjKsZzoSgvHsJdxMdD4qnG2fmD5CBgpm0HgMXLDj
# PD+nsnhQuRKDlRlSaWnLa8po3TN8LGmn8jCCBp4wggSGoAMCAQICE1EAAAAEmyQY
# a71dQjQAAAAAAAQwDQYJKoZIhvcNAQENBQAwPjETMBEGCgmSJomT8ixkARkWA09S
# RzEUMBIGCgmSJomT8ixkARkWBFdOWUMxETAPBgNVBAMTCE5ZUFIgU0cyMB4XDTI2
# MDEyNzIyMzQyMVoXDTI3MDEyNzIyMzQyMVowgYMxEzARBgoJkiaJk/IsZAEZFgNP
# UkcxFDASBgoJkiaJk/IsZAEZFgRXTllDMQ0wCwYDVQQLEwRXTllDMSwwKgYDVQQL
# EyNBZG1pbmlzdHJhdGl2ZSBhbmQgU2VydmljZSBBY2NvdW50czEZMBcGA1UEAxMQ
# TllQUiBDb2Rlc2lnbmluZzCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEB
# AJzO2Zc1h3Ny2aDjJLXjt/JIHjn0auX+Tt6hM8wqfKd1z7pLcsv41ONMG2bA/9Ki
# 5s/LO3q4CViKe9moJIAZqrIc1E35b28d5FEQkXGB8BgtulqNZGx1dAxRowv7bFgw
# NyiD4Z1mm/WdIz/6dv0f8gGoGQMdn8Y7jscmR0CsHxpyQCqIELJPABWtOulZp1v7
# Pj3rNVVeioS1NGaTaMWki+ALHgO1GstLqtThB91WPfC7qfk9FdEUe/z/IrOahANf
# zbfG7xieKJgb9WkLDNuSimLZVUN5uU4FdDYFXhNbo9POZpbJVCi1y5yPpe5nDJoI
# xOyD1Kg4el6rZ5tXKdjb0V0CAwEAAaOCAk0wggJJMD0GCSsGAQQBgjcVBwQwMC4G
# JisGAQQBgjcVCIX+w0GGwMxRhPGdCurpAoTxgXaBHofPokyE0Md6AgFkAgEJMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMAsGA1UdDwQEAwIHgDAbBgkrBgEEAYI3FQoEDjAM
# MAoGCCsGAQUFBwMDMB0GA1UdDgQWBBSR2g+trnNwL0+g5lHv6qd/Lc1kWTAfBgNV
# HSMEGDAWgBQ5e31w/QEp9Q6XZ1uxKzSU7eLvSjA+BgNVHR8ENzA1MDOgMaAvhi1o
# dHRwOi8vcGtpLndueWMub3JnL0NlcnRFbnJvbGwvTllQUiUyMFNHMi5jcmwwgbkG
# CCsGAQUFBwEBBIGsMIGpMIGmBggrBgEFBQcwAoaBmWxkYXA6Ly8vQ049TllQUiUy
# MFNHMixDTj1BSUEsQ049UHVibGljJTIwS2V5JTIwU2VydmljZXMsQ049U2Vydmlj
# ZXMsQ049Q29uZmlndXJhdGlvbixEQz1XTllDLERDPU9SRz9jQUNlcnRpZmljYXRl
# P2Jhc2U/b2JqZWN0Q2xhc3M9Y2VydGlmaWNhdGlvbkF1dGhvcml0eTA8BgNVHREE
# NTAzoDEGCisGAQQBgjcUAgOgIwwhc3ZjLWNvZGVzaWduaW5nQG55cHVibGljcmFk
# aW8ub3JnME8GCSsGAQQBgjcZAgRCMECgPgYKKwYBBAGCNxkCAaAwBC5TLTEtNS0y
# MS0xODYxNDQ4MTYxLTgwNDY4MTA0Mi0xMDA4MTUwODgwLTI5Mjg1MA0GCSqGSIb3
# DQEBDQUAA4ICAQAi/XX7/Jy595GHfEISJw750grvG3xev1ArQIrKleZYfewG0IwG
# Tboum6w8asNwlXkgPJuSNO7G64oqBiKlST08Qw7+wx9VO+Z001kBLu9ZgSk57gS4
# 2vDbxSrc5mFApRGOiUo/CTuyEpgq/WvJSHUpo/LQ5XqWhPCj1qPiMXUvpRiLV5VP
# 5NsRY+9QgVWnfFBBoErq6mhppTzqxEWQOJcYNQptHMzRvWaGQLD9bv773W/vIS8Y
# HuWy7LteUEzLafInu0Tg4y5UPa8WU5Eob+OKmACPC+FfxQcSzlQkAkwtLuq+KFHd
# r1iDACGWk3FEcJlKdJQPVSA0rBf9PFVpBtCL07piCw/0JIgnYy6gVeaqSx45sM6Y
# wRoWeFyZaLHmfvkTzGLwoesf0qQvVsjJzgR9KsHGVWkIo7Ch8wHU3+lNJI4UR+Z+
# VAf5zQcfWVWhntW/4KaBSbom3zaKUcL9MZ2Mzzx3+nNgT8+eDDr6bvpEZd0Kyoa4
# 1zmUq3NhnT6TgSVVtGKHIT7G+nrxvX6RdkivjUrgNU+A4SNwNTgt8bg66HaCPe8z
# AH9Hqb4NW/BnDqZDJBqebLFGt/JlPYsBCGWkdO2tWlqjugBp4SpyUf+6WxVBPzkC
# Be0NTyBEhZAvXPhw+OnIT09+O6CquPXuH/SMgPil0j9R8nRij8/ITLqyRjCCBrQw
# ggScoAMCAQICEA3HrFcF/yGZLkBDIgw6SYYwDQYJKoZIhvcNAQELBQAwYjELMAkG
# A1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UECxMQd3d3LmRp
# Z2ljZXJ0LmNvbTEhMB8GA1UEAxMYRGlnaUNlcnQgVHJ1c3RlZCBSb290IEc0MB4X
# DTI1MDUwNzAwMDAwMFoXDTM4MDExNDIzNTk1OVowaTELMAkGA1UEBhMCVVMxFzAV
# BgNVBAoTDkRpZ2lDZXJ0LCBJbmMuMUEwPwYDVQQDEzhEaWdpQ2VydCBUcnVzdGVk
# IEc0IFRpbWVTdGFtcGluZyBSU0E0MDk2IFNIQTI1NiAyMDI1IENBMTCCAiIwDQYJ
# KoZIhvcNAQEBBQADggIPADCCAgoCggIBALR4MdMKmEFyvjxGwBysddujRmh0tFEX
# nU2tjQ2UtZmWgyxU7UNqEY81FzJsQqr5G7A6c+Gh/qm8Xi4aPCOo2N8S9SLrC6Kb
# ltqn7SWCWgzbNfiR+2fkHUiljNOqnIVD/gG3SYDEAd4dg2dDGpeZGKe+42DFUF0m
# R/vtLa4+gKPsYfwEu7EEbkC9+0F2w4QJLVSTEG8yAR2CQWIM1iI5PHg62IVwxKSp
# O0XaF9DPfNBKS7Zazch8NF5vp7eaZ2CVNxpqumzTCNSOxm+SAWSuIr21Qomb+zzQ
# WKhxKTVVgtmUPAW35xUUFREmDrMxSNlr/NsJyUXzdtFUUt4aS4CEeIY8y9IaaGBp
# PNXKFifinT7zL2gdFpBP9qh8SdLnEut/GcalNeJQ55IuwnKCgs+nrpuQNfVmUB5K
# lCX3ZA4x5HHKS+rqBvKWxdCyQEEGcbLe1b8Aw4wJkhU1JrPsFfxW1gaou30yZ46t
# 4Y9F20HHfIY4/6vHespYMQmUiote8ladjS/nJ0+k6MvqzfpzPDOy5y6gqztiT96F
# v/9bH7mQyogxG9QEPHrPV6/7umw052AkyiLA6tQbZl1KhBtTasySkuJDpsZGKdls
# jg4u70EwgWbVRSX1Wd4+zoFpp4Ra+MlKM2baoD6x0VR4RjSpWM8o5a6D8bpfm4CL
# KczsG7ZrIGNTAgMBAAGjggFdMIIBWTASBgNVHRMBAf8ECDAGAQH/AgEAMB0GA1Ud
# DgQWBBTvb1NK6eQGfHrK4pBW9i/USezLTjAfBgNVHSMEGDAWgBTs1+OC0nFdZEzf
# Lmc/57qYrhwPTzAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0lBAwwCgYIKwYBBQUHAwgw
# dwYIKwYBBQUHAQEEazBpMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2Vy
# dC5jb20wQQYIKwYBBQUHMAKGNWh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9E
# aWdpQ2VydFRydXN0ZWRSb290RzQuY3J0MEMGA1UdHwQ8MDowOKA2oDSGMmh0dHA6
# Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRSb290RzQuY3JsMCAG
# A1UdIAQZMBcwCAYGZ4EMAQQCMAsGCWCGSAGG/WwHATANBgkqhkiG9w0BAQsFAAOC
# AgEAF877FoAc/gc9EXZxML2+C8i1NKZ/zdCHxYgaMH9Pw5tcBnPw6O6FTGNpoV2V
# 4wzSUGvI9NAzaoQk97frPBtIj+ZLzdp+yXdhOP4hCFATuNT+ReOPK0mCefSG+tXq
# GpYZ3essBS3q8nL2UwM+NMvEuBd/2vmdYxDCvwzJv2sRUoKEfJ+nN57mQfQXwcAE
# GCvRR2qKtntujB71WPYAgwPyWLKu6RnaID/B0ba2H3LUiwDRAXx1Neq9ydOal95C
# HfmTnM4I+ZI2rVQfjXQA1WSjjf4J2a7jLzWGNqNX+DF0SQzHU0pTi4dBwp9nEC8E
# AqoxW6q17r0z0noDjs6+BFo+z7bKSBwZXTRNivYuve3L2oiKNqetRHdqfMTCW/Nm
# KLJ9M+MtucVGyOxiDf06VXxyKkOirv6o02OoXN4bFzK0vlNMsvhlqgF2puE6Fndl
# ENSmE+9JGYxOGLS/D284NHNboDGcmWXfwXRy4kbu4QFhOm0xJuF2EZAOk5eCkhSx
# ZON3rGlHqhpB/8MluDezooIs8CVnrpHMiD2wL40mm53+/j7tFaxYKIqL0Q4ssd8x
# HZnIn/7GELH3IdvG2XlM9q7WP/UwgOkw/HQtyRN62JK4S1C8uw3PdBunvAZapsiI
# 5YKdvlarEvf8EA+8hcpSM9LHJmyrxaFtoza2zNaQ9k+5t1wwggbtMIIE1aADAgEC
# AhAIT9wzT35FTtvDD4/5khg1MA0GCSqGSIb3DQEBCwUAMGkxCzAJBgNVBAYTAlVT
# MRcwFQYDVQQKEw5EaWdpQ2VydCwgSW5jLjFBMD8GA1UEAxM4RGlnaUNlcnQgVHJ1
# c3RlZCBHNCBUaW1lU3RhbXBpbmcgUlNBNDA5NiBTSEEyNTYgMjAyNSBDQTEwHhcN
# MjYwODA1MDAwMDAwWhcNMzcxMTA0MjM1OTU5WjBjMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFNIQTI1NiBS
# U0E0MDk2IFRpbWVzdGFtcCBSZXNwb25kZXIgMjAyNiAxMIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEAtnum8sn+zUr41JtMZbP9OMYw+HwJDpG5xkIu/lqc
# fNYmMX81YmsUiHLbh9ykpeWBGKTLhYBrAN9Tdg/QEzG32XcObmgIblnr0CoQ3WSA
# eDZ6nH6X6VkFyYkJw3QBJREwvm4UhLzSxmwPA7cFKRTEOMsmEEj6qJk/dqLEAL+o
# QYuOwE2UuiX1Vnul8YReIyWd4kgLn9gq6LNXM0UplkR6jL/QHxmb6fMoGBJYbnaU
# I7XD6cKDpekK2SVMld4iDbzeHDtOaaxldH5IxuNusQ69nd8/ZXEiB5Hbxj3RlK13
# cX1W4DlFXKdv/CEhM8Cj1vvlmvhNroyPdRGbbpBlgyf8Wdu5N6ByhFwURn0U6ozl
# PoxN22v+fviUhP+6DR547OZnpBMWDfei1f5sVGwiiW/KQTWOK97g+4RJpPzPNV4V
# YMAwO2jM2Aty2QYPVmOQTJm0msuXnJrSbl2gf9JylpkJlWXqk1Q4LJsxz+TELoQC
# ZIljbgvTJgoPU2R12ydv8i1UqL/adelA0y7U9Pmmtbze9Xx3rtajC5SzQd1jgfwA
# wsa90v9YcSPdmeoyoBBA/27cCL237l5DTYYPDLQ4ON3OLTGWnvRb6jDrf/T75gMR
# fUzSLCBQfBusm9+mSWRlC/Df6S/e9Q8i13CuhzOT2Jx+V/nlbXM4QoBwlUAhelww
# JT0CAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFBTJY4owLtRK
# +26U8+bjQH717M3iMB8GA1UdIwQYMBaAFO9vU0rp5AZ8esrikFb2L9RJ7MtOMA4G
# A1UdDwEB/wQEAwIHgDAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDCBlQYIKwYBBQUH
# AQEEgYgwgYUwJAYIKwYBBQUHMAGGGGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBd
# BggrBgEFBQcwAoZRaHR0cDovL2NhY2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0
# VHJ1c3RlZEc0VGltZVN0YW1waW5nUlNBNDA5NlNIQTI1NjIwMjVDQTEuY3J0MF8G
# A1UdHwRYMFYwVKBSoFCGTmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2Vy
# dFRydXN0ZWRHNFRpbWVTdGFtcGluZ1JTQTQwOTZTSEEyNTYyMDI1Q0ExLmNybDAg
# BgNVHSAEGTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQAD
# ggIBAI3FOmEenVIK35msCYB+fShAsWvSYvLBItoNdAgQ2jIqrGsVsluXMJU/+mRe
# bBc52s6lbKAvOVPXaizmKkMLLflEEKDZQx4CkS2t8aHPjkXha3hYZ010htFa3dhN
# gmalH5vuWvh3tTCf4frTS7gPtGc4Z/xaPhQ2AB1mR8eEe/WbH0RWHvVIl6VwQ3+g
# 5FKNfN2N/DWJkf13w2H+2GfqEfbd35Ww8CvoYBjLNIDTadcPWdgsjsiOaK/7EsKJ
# gLjUNIVgvcaFOLLQ/GlrA+0ZHJoFUbOr5SJN8zykPspXIXlpDJY/gqFUZRROeab9
# GVgmhbdOJcD/63RhxPahFUGbckRONqMe6DYAv6/mOG0pWd3cPStsdcS7buj5Dyni
# wRY8yooMH6ptx5vpP/pZzBPBeZD2U4IsthyxB5Jaa8qrOkB5z160TXiM5ADMspZ0
# TfD9MJoq0tFpFPssKRFhWeEDYPvcUuN7U7lvcdHl4ezQ3NT/7Ffs1sR1yh/LRbdZ
# 3B3Vc6q2WmD8mDC0p9kzl2o73iVtS946IkEj7FkRsZGww1teYxERROC745xrtjvc
# w9ZyyUjHZWGRIpJeMNsPquCDf0fkyHtB+J4AiNZqCQk23rxh+KbpyMTNVKItJ5l9
# 2Svl20U9NbqMBOVYl1h54NEYLJq1/xHWFKPNK903zJZA9P2DMYIFIDCCBRwCAQEw
# VTA+MRMwEQYKCZImiZPyLGQBGRYDT1JHMRQwEgYKCZImiZPyLGQBGRYEV05ZQzER
# MA8GA1UEAxMITllQUiBTRzICE1EAAAAEmyQYa71dQjQAAAAAAAQwCQYFKw4DAhoF
# AKB4MBgGCisGAQQBgjcCAQwxCjAIoAKAAKECgAAwGQYJKoZIhvcNAQkDMQwGCisG
# AQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQBgjcCARUwIwYJKoZIhvcN
# AQkEMRYEFLIn12Qz/37bc61HLuxXyS98LxW/MA0GCSqGSIb3DQEBAQUABIIBAJco
# iOPgH7VDxl1DYIOE3Kv31TQwhQm1i7Z8NvDejiaFnFWfiiVOr/roo4EqXEMjSQ15
# r7Pu3RY7sTpBnw7kQ/FcvazgogQJDsui43cAU3bbjDQ+zC+8rn+CIJKKwdQbd6iJ
# WoRL4N0TR4j2KqZrBkxIpRfTNOJYkJpqkKZVUwBWdHcdLuoyg6vYforVXhfVaBGi
# aPRBeUvpULMtvJ0mQoz+xxVWgph8tDm2tMnox7O/EFEjdNp1WYnZr42UEP5vgPVi
# RiYTfSYvMecT7MATwup64VqPvF+3tEVY9UjYdtwBJH48RpH5GhGpUqkv/0/0YbcC
# CVtQr+L7Gpckwh4MBbahggMmMIIDIgYJKoZIhvcNAQkGMYIDEzCCAw8CAQEwfTBp
# MQswCQYDVQQGEwJVUzEXMBUGA1UEChMORGlnaUNlcnQsIEluYy4xQTA/BgNVBAMT
# OERpZ2lDZXJ0IFRydXN0ZWQgRzQgVGltZVN0YW1waW5nIFJTQTQwOTYgU0hBMjU2
# IDIwMjUgQ0ExAhAIT9wzT35FTtvDD4/5khg1MA0GCWCGSAFlAwQCAQUAoGkwGAYJ
# KoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkqhkiG9w0BCQUxDxcNMjYxMDI5MTc1
# NjEzWjAvBgkqhkiG9w0BCQQxIgQgEGJPV0GQ38ySNvOtY1414G2NDpref5RlNSWq
# 8LjhweowDQYJKoZIhvcNAQEBBQAEggIAZyPTaEskHXrsTomAbRNeaXuFDOIb1bA1
# lbWUOMHP2EHARDlVbSl+1Y83Pl6DdDRECBtXCZjiq6aRbRmuOxCTNv5RuvBc2dMq
# umWUd8jVTB/ig1LZSTfmoCgJVk5H0U+6tfLEYuuqpsRQCid1WBrr7cKpw4ptp2ZX
# Ldp2n97tlxFXtldVBBWi707HAY0b8oCq/77YVuW4FUKYW/kJuhWpxGIfLDfRSKjH
# XgXE5S9mbZjE3TDmauUY9+ef8CWw2Zq+KAfHaIHt9mehXtkBDNxuS2NNPWhPL9AC
# ibdaTO/Mcvg+xFuNwWHDmcYoOM3EPSKB2DrP08e0ku9wp0x37iit4kuMiYWaS6PP
# mpKGW7mVIjCfYPH5fyP6634qLfBJNw6uWy0ZGVZWxmQgKSvTB1JHTeQF5gTO2AMC
# sY5gYHkzoCo0b2XfUvGNDeYdSxQBQNX7liUOaTU9AxSrj0kv25Wspa7m10i1WuHE
# D5qbWD8yUYX0bQTw09LaVJP/o/gvRdj835wTs6Vc9r+KrLsMrjQyKL1kVEeRXKBE
# WnSj9Le+OTcOje5n0u4gKVNI/g4au5hkMtYQmPRvW367IxOCiugVtEPx5rT0xyMn
# qESe0HkOg4oTbrsCVV/6kdSWe6Er0ZvAS6HjQsT8kXuNRAU7E9ltnXn2acGUoVTD
# iHbi4RuZ3F0=
# SIG # End signature block
