param([string]$Out, [int]$Size = 512)
Add-Type -AssemblyName System.Drawing
$S = 1024  # draw big, scale down at the end
$bmp = New-Object System.Drawing.Bitmap $S, $S
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.TextRenderingHint = 'AntiAliasGridFit'
$g.InterpolationMode = 'HighQualityBicubic'
$g.Clear([System.Drawing.Color]::Transparent)

function C($a, $r, $gg, $b) { [System.Drawing.Color]::FromArgb($a, $r, $gg, $b) }
function RoundRect($x, $y, $w, $h, $r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $r
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# --- background: dark navy rounded square
$bg = RoundRect 0 0 $S $S 170
$bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.Point]::new(0, 0)), ([System.Drawing.Point]::new($S, $S)), (C 255 24 33 48), (C 255 9 13 22)
$g.FillPath($bgBrush, $bg)
$g.SetClip($bg)

# --- felt disc
$cx = $S / 2; $cy = $S / 2
$fr = 372
$felt = New-Object System.Drawing.Drawing2D.GraphicsPath
$felt.AddEllipse($cx - $fr, $cy - $fr, 2 * $fr, 2 * $fr)
$fb = New-Object System.Drawing.Drawing2D.PathGradientBrush $felt
$fb.CenterColor = C 255 46 140 92
$fb.SurroundColors = @(C 255 10 52 34)
$fb.CenterPoint = [System.Drawing.PointF]::new($cx, $cy - 60)
$g.FillPath($fb, $felt)

# --- the Fojji ring: four arcs with gaps, top-right one light blue
$rr = 404; $rw = 60; $gap = 7
$rect = [System.Drawing.RectangleF]::new($cx - $rr, $cy - $rr, 2 * $rr, 2 * $rr)
for ($i = 0; $i -lt 4; $i++) {
    $start = $i * 90 + $gap / 2
    $sweep = 90 - $gap
    # soft shadow
    for ($k = 6; $k -ge 1; $k--) {
        $sp = New-Object System.Drawing.Pen (C 22 0 0 0), ($rw + $k * 4)
        $sr = [System.Drawing.RectangleF]::new($rect.X + 6, $rect.Y + 10, $rect.Width, $rect.Height)
        $g.DrawArc($sp, $sr, $start, $sweep)
    }
    $col = if ($i -eq 3) { C 255 62 198 236 } else { C 255 245 247 250 }
    $pen = New-Object System.Drawing.Pen $col, $rw
    $g.DrawArc($pen, $rect, $start, $sweep)
}

# --- cards
$cw = 300; $ch = 420
$rankFont = New-Object System.Drawing.Font 'Georgia', 78, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$smallSuit = New-Object System.Drawing.Font 'Segoe UI Symbol', 64, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$bigSuit = New-Object System.Drawing.Font 'Segoe UI Symbol', 230, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
$center = New-Object System.Drawing.StringFormat
$center.Alignment = 'Center'; $center.LineAlignment = 'Center'

function Card($ox, $oy, $angle, $suit, $col) {
    $state = $g.Save()
    $g.TranslateTransform($ox, $oy)
    $g.RotateTransform($angle)
    $x = - $cw / 2; $y = - $ch / 2
    # shadow
    for ($k = 8; $k -ge 1; $k--) {
        $sh = RoundRect ($x + 10 - $k * 2) ($y + 18 - $k * 2) ($cw + $k * 4) ($ch + $k * 4) (30 + $k * 2)
        $g.FillPath((New-Object System.Drawing.SolidBrush (C 18 0 0 0)), $sh)
    }
    $body = RoundRect $x $y $cw $ch 30
    $cb = New-Object System.Drawing.Drawing2D.LinearGradientBrush ([System.Drawing.PointF]::new($x, $y)), ([System.Drawing.PointF]::new($x, $y + $ch)), (C 255 255 255 255), (C 255 226 230 236)
    $g.FillPath($cb, $body)
    $g.DrawPath((New-Object System.Drawing.Pen (C 255 200 205 214), 4), $body)
    $ink = New-Object System.Drawing.SolidBrush $col
    $g.DrawString('A', $rankFont, $ink, [System.Drawing.RectangleF]::new($x + 12, $y + 16, 90, 90), $center)
    $g.DrawString($suit, $smallSuit, $ink, [System.Drawing.RectangleF]::new($x + 12, $y + 98, 90, 80), $center)
    $g.DrawString($suit, $bigSuit, $ink, [System.Drawing.RectangleF]::new($x, $y + 40, $cw, $ch), $center)
    # bottom-right corner, upside down
    $g.TranslateTransform(0, 0)
    $g.RotateTransform(180)
    $g.DrawString('A', $rankFont, $ink, [System.Drawing.RectangleF]::new($x + 12, $y + 16, 90, 90), $center)
    $g.DrawString($suit, $smallSuit, $ink, [System.Drawing.RectangleF]::new($x + 12, $y + 98, 90, 80), $center)
    $g.Restore($state)
}

$spade = [string][char]0x2660
$heart = [string][char]0x2665
Card ($cx - 95) ($cy + 20) -13 $spade (C 255 22 26 34)
Card ($cx + 95) ($cy + 10) 11 $heart (C 255 214 40 52)

# --- a gold chip at the bottom
$chipR = 92; $chx = $cx; $chy = $cy + 300
for ($k = 6; $k -ge 1; $k--) {
    $g.FillEllipse((New-Object System.Drawing.SolidBrush (C 26 0 0 0)), $chx - $chipR - $k * 2 + 6, $chy - $chipR - $k * 2 + 12, 2 * ($chipR + $k * 2), 2 * ($chipR + $k * 2))
}
$g.FillEllipse((New-Object System.Drawing.SolidBrush (C 255 255 205 64)), $chx - $chipR, $chy - $chipR, 2 * $chipR, 2 * $chipR)
$stripe = New-Object System.Drawing.Pen (C 255 255 255 255), 26
for ($i = 0; $i -lt 6; $i++) {
    $g.DrawArc($stripe, $chx - $chipR + 13, $chy - $chipR + 13, 2 * $chipR - 26, 2 * $chipR - 26, $i * 60 + 15, 22)
}
$g.FillEllipse((New-Object System.Drawing.SolidBrush (C 255 222 160 30)), $chx - 58, $chy - 58, 116, 116)
$g.DrawEllipse((New-Object System.Drawing.Pen (C 255 255 228 140), 5), $chx - 58, $chy - 58, 116, 116)
$fFont = New-Object System.Drawing.Font 'Segoe UI', 72, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
$g.DrawString('F', $fFont, (New-Object System.Drawing.SolidBrush (C 255 255 250 235)), [System.Drawing.RectangleF]::new($chx - 58, $chy - 54, 116, 116), $center)

$g.ResetClip()
$g.Dispose()

$final = New-Object System.Drawing.Bitmap $Size, $Size
$g2 = [System.Drawing.Graphics]::FromImage($final)
$g2.InterpolationMode = 'HighQualityBicubic'
$g2.SmoothingMode = 'AntiAlias'
$g2.PixelOffsetMode = 'HighQuality'
$g2.DrawImage($bmp, 0, 0, $Size, $Size)
$g2.Dispose()
$final.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"saved $Out"
