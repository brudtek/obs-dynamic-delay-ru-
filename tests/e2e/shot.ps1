param([int]$X, [int]$Y, [int]$W, [int]$H, [string]$Out)
# Screenshot of a screen rectangle in physical pixels (the coordinates UI Automation reports).
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System.Runtime.InteropServices;
public static class DpiAware { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }
'@
[DpiAware]::SetProcessDPIAware() | Out-Null
$bmp = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($X, $Y, 0, 0, (New-Object System.Drawing.Size $W, $H))
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
Write-Output "saved $Out"
