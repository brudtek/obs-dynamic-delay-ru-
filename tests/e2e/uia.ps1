param(
	[string]$Action = 'dump',
	[string]$Name = '',
	[int]$Depth = 6
)
# Windows UI Automation helper for driving a test OBS (process obs64).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI,
# so Cyrillic names are passed in via -Name (see names.json).
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$AE = [System.Windows.Automation.AutomationElement]
$TS = [System.Windows.Automation.TreeScope]

$procs = Get-Process obs64 -ErrorAction SilentlyContinue
if (-not $procs) { Write-Output 'OBS is not running'; exit 1 }
$pidCond = New-Object System.Windows.Automation.PropertyCondition($AE::ProcessIdProperty, $procs[0].Id)
$windows = $AE::RootElement.FindAll($TS::Children, $pidCond)

function Show-Tree($el, $level, $max) {
	if ($level -gt $max) { return }
	$c = $el.Current
	$r = $c.BoundingRectangle
	$val = ''
	$vp = $null
	if ($el.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) { $val = ' value=' + $vp.Current.Value }
	Write-Output ('{0}{1} "{2}"{3} [{4},{5} {6}x{7}]' -f ('  ' * $level), $c.ControlType.ProgrammaticName.Replace('ControlType.', ''), $c.Name, $val, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height)
	$walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
	$child = $walker.GetFirstChild($el)
	while ($child) {
		Show-Tree $child ($level + 1) $max
		$child = $walker.GetNextSibling($child)
	}
}

function Find-ByName($name) {
	$tops = $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ProcessId -eq $procs[0].Id }
	foreach ($w in $tops) {
		if ($w.Current.Name -eq $name) { return $w }
		$cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $name)
		$found = $w.FindFirst($TS::Descendants, $cond)
		if ($found) { return $found }
	}
	return $null
}

switch ($Action) {
	'windows' { foreach ($w in $windows) { $r = $w.Current.BoundingRectangle; Write-Output ('"{0}" [{1},{2} {3}x{4}]' -f $w.Current.Name, [int]$r.X, [int]$r.Y, [int]$r.Width, [int]$r.Height) } }
	'dump' {
		if ($Name) { $root = Find-ByName $Name; if (-not $root) { Write-Output "not found: $Name"; exit 2 }; Show-Tree $root 0 $Depth }
		else { foreach ($w in $windows) { Show-Tree $w 0 $Depth } }
	}
	'expand' {
		$el = Find-ByName $Name
		if (-not $el) { Write-Output "not found: $Name"; exit 2 }
		$pattern = $null
		if ($el.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$pattern)) { $pattern.Expand(); Write-Output "expanded: $Name" }
		Start-Sleep -Milliseconds 700
	}
	'menuitem' {
		# -Name "menu|item": opens a menu bar entry and invokes an item in its popup.
		$menuName, $itemName = $Name -split '\|', 2
		$menu = Find-ByName $menuName
		if (-not $menu) { Write-Output "not found: $menuName"; exit 2 }
		$menu.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
		$cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $itemName)
		for ($i = 0; $i -lt 30; $i++) {
			Start-Sleep -Milliseconds 100
			$found = $menu.FindFirst($TS::Descendants, $cond)
			if (-not $found) {
				$popups = $AE::RootElement.FindAll($TS::Children, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ProcessId -eq $procs[0].Id -and $_.Current.Name -ne $windows[0].Current.Name }
				foreach ($p in $popups) { $found = $p.FindFirst($TS::Descendants, $cond); if ($found) { break } }
			}
			if ($found) {
				$pattern = $null
				if ($found.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke() }
				Write-Output "invoked menu item: $itemName"
				exit 0
			}
		}
		Write-Output "menu item not found: $itemName"
		exit 2
	}
	'state' {
		# Texts, progress and button captions of the dock named -Name.
		$dock = Find-ByName $Name
		if (-not $dock) { Write-Output 'dock not found'; exit 2 }
		$parts = @()
		foreach ($t in $dock.FindAll($TS::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
			$ct = $t.Current.ControlType.ProgrammaticName
			if ($ct -eq 'ControlType.Text' -or $ct -eq 'ControlType.Button') { $parts += $t.Current.Name }
			if ($ct -eq 'ControlType.ProgressBar') {
				$vp = $null
				if ($t.TryGetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern, [ref]$vp)) { $parts += ('progress=' + $vp.Current.Value) }
			}
		}
		Write-Output ($parts -join ' | ')
	}
	'slider' {
		$dock = Find-ByName $Name
		$cond = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Slider)
		$slider = $dock.FindFirst($TS::Descendants, $cond)
		$rv = $slider.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern)
		$rv.SetValue([double]$Depth)
		Write-Output ('slider value=' + $rv.Current.Value)
	}
	'close' {
		$main = $windows | Where-Object { $_.Current.Name -like 'OBS *' } | Select-Object -First 1
		$main.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern).Close()
		Write-Output 'close requested'
	}
	'invoke' {
		$el = Find-ByName $Name
		if (-not $el) { Write-Output "not found: $Name"; exit 2 }
		$pattern = $null
		if ($el.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke(); Write-Output "invoked: $Name" }
		elseif ($el.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) { $pattern.Toggle(); Write-Output "toggled: $Name" }
		else { Write-Output "no pattern: $Name" }
	}
}
