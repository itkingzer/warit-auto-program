function Find-NewAppInstallers([string]$AppsPath, [object[]]$Entries) {
    $folder = Get-Item -LiteralPath $AppsPath -ErrorAction SilentlyContinue
    if (-not $folder -or -not $folder.PSIsContainer -or
        ($folder.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return }

    $folders = @($folder) + @(Get-ChildItem -LiteralPath $AppsPath -Directory | Where-Object {
        -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
    })
    foreach ($directory in $folders) {
        $subfolder = if ($directory.FullName -ne $folder.FullName) { $directory.Name } else { '' }
        $configured = @($Entries | Where-Object { [string]$_.Subfolder -eq [string]$subfolder })
        foreach ($file in Get-ChildItem -LiteralPath $directory.FullName -File) {
            if ($file.Extension -notin '.exe', '.msi' -or $file.Length -eq 0 -or
                ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
            if ($configured | Where-Object { $file.Name -like $_.File }) { continue }
            [pscustomobject]@{ File = $file; Subfolder = $subfolder }
        }
    }
}

function Show-AppRecipeEditor($Owner) {
    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="สร้างรายการติดตั้งอัตโนมัติ" Width="720" Height="710" MinWidth="560" MinHeight="510"
        Background="{DynamicResource CanvasBrush}" Foreground="{DynamicResource TextBrush}"
        FontFamily="Segoe UI" FontSize="14" WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource ConsoleBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="MinHeight" Value="32"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <Border DockPanel.Dock="Top" Background="{DynamicResource HeroBrush}" Padding="24,18">
      <TextBlock Text="สร้างรายการติดตั้งอัตโนมัติ" FontSize="25" FontWeight="SemiBold" TextWrapping="Wrap"/>
    </Border>
    <Border DockPanel.Dock="Bottom" Background="{DynamicResource SurfaceBrush}"
            BorderBrush="{DynamicResource LineBrush}" BorderThickness="0,1,0,0" Padding="24,12">
      <StackPanel>
        <TextBlock Name="Problem" Foreground="{DynamicResource AccentBrush}" TextWrapping="Wrap"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Button Content="ยกเลิก" IsCancel="True" Margin="0,0,8,0"/>
          <Button Name="SaveRecipe" Content="เพิ่มในรายการ" IsDefault="True" Style="{DynamicResource PrimaryButton}"/>
        </StackPanel>
      </StackPanel>
    </Border>
    <ScrollViewer VerticalScrollBarVisibility="Auto">
      <StackPanel Margin="24,16">
        <Border Style="{DynamicResource Card}" CornerRadius="10" Padding="14" Margin="0,0,0,12">
          <StackPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="180"/></Grid.ColumnDefinitions>
              <StackPanel Margin="0,0,12,0">
                <TextBlock Text="ชื่อโปรแกรม" Margin="0,0,0,4"/>
                <TextBox Name="RecipeName" AutomationProperties.Name="ชื่อโปรแกรม"/>
              </StackPanel>
              <StackPanel Grid.Column="1">
                <TextBlock Text="หมวดโปรแกรม" Margin="0,0,0,4"/>
                <ComboBox Name="RecipeCategory" SelectedIndex="0" AutomationProperties.Name="หมวดโปรแกรม">
                  <ComboBoxItem Content="โปรแกรมทั่วไป"/>
                  <ComboBoxItem Content="โปรแกรม Crack"/>
                </ComboBox>
              </StackPanel>
            </Grid>
            <TextBlock Text="ชื่อใน Installed apps (ไม่บังคับ)" Margin="0,10,0,4"/>
            <TextBox Name="DetectName" AutomationProperties.Name="ชื่อใน Installed apps"/>
            <CheckBox Name="Reinstall" Content="อนุญาตให้ติดตั้งทับเมื่อพบว่าลงแล้ว" Margin="0,8,0,0"/>
          </StackPanel>
        </Border>
        <Border Style="{DynamicResource Card}" CornerRadius="10" Padding="14" Margin="0,0,0,12">
          <StackPanel>
            <TextBlock Text="ตัวติดตั้งหลัก" FontSize="17" FontWeight="SemiBold"/>
            <DockPanel Margin="0,8,0,10">
              <Button Name="ChooseMain" DockPanel.Dock="Right" Content="เลือกไฟล์…" Margin="10,0,0,0"/>
              <TextBlock Name="MainPath" Text="ยังไม่ได้เลือกไฟล์" VerticalAlignment="Center"
                         TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
            </DockPanel>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="155"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <StackPanel Margin="0,0,12,0">
                <TextBlock Text="วิธีติดตั้ง" Margin="0,0,0,4"/>
                <ComboBox Name="Mode" SelectedIndex="0" AutomationProperties.Name="วิธีติดตั้ง">
                  <ComboBoxItem Content="Silent"/>
                  <ComboBoxItem Name="CmdMode" Content="รันผ่าน CMD"/>
                  <ComboBoxItem Content="เปิดตัวติดตั้งให้กดเอง"/>
                </ComboBox>
              </StackPanel>
              <StackPanel Grid.Column="1">
                <TextBlock Text="พารามิเตอร์ตัวติดตั้ง" Margin="0,0,0,4"/>
                <TextBox Name="Arguments" AutomationProperties.Name="พารามิเตอร์ตัวติดตั้ง"/>
              </StackPanel>
            </Grid>
            <TextBlock Name="ModeHint" Margin="0,6,0,0" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
          </StackPanel>
        </Border>
        <Border Style="{DynamicResource Card}" CornerRadius="10" Padding="14">
          <StackPanel>
            <TextBlock Text="ลำดับการติดตั้ง" FontSize="17" FontWeight="SemiBold"/>
            <WrapPanel Margin="0,8">
              <Button Name="AddBefore" Content="+ ก่อนตัวติดตั้งหลัก" Margin="0,0,8,0"/>
              <Button Name="AddStep" Content="+ หลังตัวติดตั้งหลัก"/>
            </WrapPanel>
            <ListBox Name="StepList" MinHeight="64" MaxHeight="168"
                     Background="{DynamicResource ConsoleBrush}" Foreground="{DynamicResource TextBrush}"
                     BorderBrush="{DynamicResource LineBrush}" DisplayMemberPath="Label"
                     AutomationProperties.Name="ลำดับการติดตั้ง"/>
            <WrapPanel Margin="0,8,0,0">
              <Button Name="MoveUp" Content="เลื่อนขึ้น" Margin="0,0,8,0"/>
              <Button Name="MoveDown" Content="เลื่อนลง" Margin="0,0,8,0"/>
              <Button Name="RemoveStep" Content="ลบขั้นตอน"/>
            </WrapPanel>
            <StackPanel Name="StepOptions" Margin="0,8,0,0" Visibility="Collapsed">
              <TextBlock Text="พารามิเตอร์ขั้นตอนที่เลือก (Silent EXE ต้องระบุ)" Margin="0,0,0,4"/>
              <TextBox Name="StepArguments" AutomationProperties.Name="พารามิเตอร์ขั้นตอนที่เลือก"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
    $editor = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
    $editor.Owner = $Owner
    $editor.Icon = $Owner.Icon
    $editor.Resources.MergedDictionaries.Add($Owner.Resources)
    $fields = @{}
    foreach ($id in 'RecipeName','RecipeCategory','DetectName','Reinstall','Mode','CmdMode','Arguments','ModeHint','MainPath',
        'ChooseMain','AddBefore','AddStep','StepList','StepOptions','StepArguments','MoveUp','MoveDown','RemoveStep','SaveRecipe','Problem') {
        $fields[$id] = $editor.FindName($id)
    }
    $steps = [Collections.Generic.List[object]]::new()
    $main = @{ Main = $true; File = $null }
    $steps.Add($main)
    $result = @{ Draft = $null }

    function Update-RecipeButtons {
        $index = $fields.StepList.SelectedIndex
        $fields.MoveUp.IsEnabled = $index -gt 0
        $fields.MoveDown.IsEnabled = $index -ge 0 -and $index -lt ($steps.Count - 1)
        $fields.RemoveStep.IsEnabled = $index -ge 0 -and -not $steps[$index].Main
        $editArguments = $index -ge 0 -and -not $steps[$index].Main -and $steps[$index].File.Extension -ne '.reg'
        $fields.StepOptions.Visibility = if ($editArguments) { 'Visible' } else { 'Collapsed' }
        if ($editArguments) { $fields.StepArguments.Text = [string]$steps[$index].Arguments }
    }

    function Update-RecipeSteps([int]$Index) {
        $fields.StepList.Items.Clear()
        for ($i = 0; $i -lt $steps.Count; $i++) {
            $step = $steps[$i]
            $kind = if ($step.Main) {
                @('Silent · ไฟล์หลัก','CMD · ไฟล์หลัก','กดติดตั้งเอง · ไฟล์หลัก')[$fields.Mode.SelectedIndex]
            } elseif ($step.File.Extension -eq '.reg') { 'นำเข้า Registry' }
            elseif ($step.File.Extension -in '.exe','.msi') { 'Silent' } else { 'รันผ่าน CMD' }
            $filename = if ($step.File) { $step.File.Name } else { 'ยังไม่ได้เลือกไฟล์' }
            [void]$fields.StepList.Items.Add([pscustomobject]@{ Label = "$($i + 1). $kind   $filename" })
        }
        $fields.StepList.SelectedIndex = $Index
        Update-RecipeButtons
    }

    function Select-RecipeFile([string]$Filter) {
        $picker = [Microsoft.Win32.OpenFileDialog]::new()
        $picker.Filter = $Filter
        if ($picker.ShowDialog($editor) -ne $true) { return }
        $file = Get-Item -LiteralPath $picker.FileName -ErrorAction Stop
        if ($file.PSIsContainer -or -not $file.Length -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "ไม่รองรับไฟล์ $($file.Name)"
        }
        $file
    }

    function Update-RecipeMode {
        $fields.ModeHint.Text = if ($fields.Mode.SelectedIndex -eq 1) { 'ใส่พารามิเตอร์ที่ไฟล์หลักต้องใช้เมื่อรันผ่าน CMD' }
            elseif ($fields.Mode.SelectedIndex -eq 2) { 'เปิดหน้าต่างตัวติดตั้งให้ทำตามขั้นตอน' }
            elseif ($main.File.Extension -eq '.msi') { 'MSI จะใช้ /qn /norestart อัตโนมัติ' }
            else { 'สำหรับ EXE ให้ใช้พารามิเตอร์ Silent ตามคู่มือของตัวติดตั้ง' }
        Update-RecipeSteps $fields.StepList.SelectedIndex
    }

    $fields.StepList.Add_SelectionChanged({ Update-RecipeButtons })
    $fields.StepArguments.Add_TextChanged({
        $index = $fields.StepList.SelectedIndex
        if ($fields.StepOptions.Visibility -eq 'Visible' -and $index -ge 0 -and -not $steps[$index].Main) {
            $steps[$index].Arguments = $fields.StepArguments.Text
        }
    })
    $fields.Mode.Add_SelectionChanged({ Update-RecipeMode })
    $fields.ChooseMain.Add_Click({
        try {
            $file = Select-RecipeFile 'ตัวติดตั้ง (*.exe;*.msi;*.cmd;*.bat)|*.exe;*.msi;*.cmd;*.bat'
            if (-not $file) { return }
            if ($file.Extension -notin '.exe','.msi','.cmd','.bat') { throw 'เลือกไฟล์ EXE, MSI, CMD หรือ BAT' }
            if (-not $fields.RecipeName.Text.Trim() -or $fields.RecipeName.Text -eq $main.File.BaseName) {
                $fields.RecipeName.Text = $file.BaseName
            }
            $main.File = $file
            $fields.MainPath.Text = $file.FullName
            $fields.Arguments.Clear()
            $fields.Mode.SelectedIndex = [int]($file.Extension -in '.cmd','.bat')
            $fields.CmdMode.IsEnabled = $file.Extension -ne '.msi'
            $fields.Mode.IsEnabled = $file.Extension -in '.exe','.msi'
            $fields.Problem.Text = ''
            Update-RecipeMode
        } catch { $fields.Problem.Text = $_.Exception.Message }
    })
    function Add-RecipeStep([int]$Index) {
        try {
            $file = Select-RecipeFile 'ขั้นตอนเพิ่มเติม (*.exe;*.msi;*.reg;*.cmd;*.bat)|*.exe;*.msi;*.reg;*.cmd;*.bat'
            if (-not $file) { return }
            if ($file.Extension -notin '.exe','.msi','.reg','.cmd','.bat') { throw 'เลือกไฟล์ EXE, MSI, REG, CMD หรือ BAT' }
            $steps.Insert($Index, @{ Main = $false; File = $file; Arguments = '' })
            $fields.Problem.Text = ''
            Update-RecipeSteps $Index
        } catch { $fields.Problem.Text = $_.Exception.Message }
    }
    $fields.AddBefore.Add_Click({ Add-RecipeStep ($steps.IndexOf($main)) })
    $fields.AddStep.Add_Click({ Add-RecipeStep $steps.Count })
    $fields.MoveUp.Add_Click({
        $index = $fields.StepList.SelectedIndex
        $step = $steps[$index]
        $steps.RemoveAt($index)
        $steps.Insert($index - 1, $step)
        Update-RecipeSteps ($index - 1)
    })
    $fields.MoveDown.Add_Click({
        $index = $fields.StepList.SelectedIndex
        $step = $steps[$index]
        $steps.RemoveAt($index)
        $steps.Insert($index + 1, $step)
        Update-RecipeSteps ($index + 1)
    })
    $fields.RemoveStep.Add_Click({
        $index = $fields.StepList.SelectedIndex
        $steps.RemoveAt($index)
        Update-RecipeSteps ([Math]::Min($index, $steps.Count - 1))
    })
    $fields.SaveRecipe.Add_Click({
        try {
            if (-not $main.File) { throw 'เลือกไฟล์หลักก่อนบันทึก' }
            $name = $fields.RecipeName.Text.Trim()
            if (-not $name) { throw 'ระบุชื่อโปรแกรม' }
            $mode = @('Silent','Cmd','Interactive')[$fields.Mode.SelectedIndex]
            $arguments = $fields.Arguments.Text.Trim()
            if ($mode -eq 'Silent' -and $main.File.Extension -eq '.exe' -and -not $arguments) {
                [void]$fields.Arguments.Focus()
                throw 'ระบุพารามิเตอร์ Silent ของไฟล์ EXE'
            }
            $sources = @{}
            foreach ($step in $steps) {
                $file = $step.File
                if ($sources.ContainsKey($file.Name)) { throw "ไฟล์ซ้ำในลำดับติดตั้ง: $($file.Name)" }
                if (-not $step.Main -and $file.Extension -eq '.exe' -and [string]::IsNullOrWhiteSpace($step.Arguments)) {
                    throw "ระบุพารามิเตอร์ Silent ของไฟล์ $($file.Name)"
                }
                $sources[$file.Name] = $file.FullName
            }
            $result.Draft = [pscustomobject]@{
                Name = $name; File = $main.File; Category = $fields.RecipeCategory.SelectedIndex
                DetectName = $fields.DetectName.Text.Trim(); Mode = $mode; Arguments = $arguments
                Sources = $sources; Reinstall = [bool]$fields.Reinstall.IsChecked
                Steps = @(foreach ($step in $steps) {
                    [pscustomobject]@{ File = $step.File.Name; Main = $step.Main; Arguments = ([string]$step.Arguments).Trim() }
                })
            }
            $editor.DialogResult = $true
        } catch { $fields.Problem.Text = $_.Exception.Message }
    })
    Update-RecipeMode
    if ($editor.ShowDialog() -eq $true) { $result.Draft }
}

function Show-AppSelection($Owner, [string]$AppsPath, [string]$ConfigPath, $Config) {
    [xml]$layout = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="เลือกรายการโปรแกรม" Width="760" Height="690" MinWidth="530" MinHeight="470"
        Background="{DynamicResource CanvasBrush}" Foreground="{DynamicResource TextBrush}"
        FontFamily="Segoe UI" FontSize="14" UseLayoutRounding="True"
        WindowStartupLocation="CenterOwner" ShowInTaskbar="False">
  <Window.Resources>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource ConsoleBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="CaretBrush" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="MinHeight" Value="32"/>
      <Style.Triggers>
        <Trigger Property="IsKeyboardFocused" Value="True">
          <Setter Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Margin" Value="0,0,18,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="MinHeight" Value="28"/>
    </Style>
  </Window.Resources>
  <DockPanel>
    <StackPanel DockPanel.Dock="Top">
      <Border Background="{DynamicResource HeroBrush}" Padding="24,20">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" Margin="16,0,0,0" VerticalAlignment="Center">
            <Button Name="Browse" Content="เพิ่มโปรแกรม…" Margin="0,0,8,0"/>
            <Button Name="Scan" Content="ตรวจหาไฟล์ใหม่"/>
          </StackPanel>
          <StackPanel>
            <TextBlock Text="เลือกรายการโปรแกรม" FontSize="26" FontWeight="SemiBold" TextWrapping="Wrap"/>
            <TextBlock Text="รายการที่เลือกจะใช้เมื่อกดเริ่มงาน" Foreground="{DynamicResource MutedBrush}" Margin="0,5,0,0" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </Border>
      <StackPanel Margin="24,12,24,6">
        <TextBlock Text="ค้นหาจากชื่อโปรแกรมหรือไฟล์" Foreground="{DynamicResource MutedBrush}" Margin="0,0,0,4"/>
        <TextBox Name="Search" AutomationProperties.Name="ค้นหาจากชื่อโปรแกรมหรือไฟล์"/>
        <WrapPanel Margin="0,6,0,0">
          <RadioButton Name="AllFilter" Content="ทั้งหมด" IsChecked="True"/>
          <RadioButton Name="SelectedFilter" Content="ที่เลือก"/>
          <RadioButton Name="NewFilter" Content="ไฟล์ใหม่"/>
          <ComboBox Name="CategoryFilter" SelectedIndex="0" MinWidth="150" Margin="0,3,0,0" AutomationProperties.Name="หมวดโปรแกรม">
            <ComboBoxItem Content="ทุกหมวด"/>
            <ComboBoxItem Content="โปรแกรมทั่วไป"/>
            <ComboBoxItem Content="โปรแกรม Crack"/>
          </ComboBox>
        </WrapPanel>
      </StackPanel>
    </StackPanel>
    <Border DockPanel.Dock="Bottom" Background="{DynamicResource SurfaceBrush}"
            BorderBrush="{DynamicResource LineBrush}" BorderThickness="0,1,0,0" Padding="24,12">
      <StackPanel>
        <TextBlock Name="Problem" Foreground="{DynamicResource AccentBrush}" TextWrapping="Wrap"/>
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" Margin="12,0,0,0">
            <Button Content="ยกเลิก" IsCancel="True" Margin="0,0,8,0"/>
            <Button Name="Save" Content="บันทึกการเลือก" IsDefault="True" Style="{DynamicResource PrimaryButton}"/>
          </StackPanel>
          <StackPanel VerticalAlignment="Center">
            <TextBlock Name="SelectionTotal" FontWeight="SemiBold" AutomationProperties.LiveSetting="Polite"/>
            <TextBlock Name="ScanStatus" Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap"/>
          </StackPanel>
        </DockPanel>
      </StackPanel>
    </Border>
    <ScrollViewer Name="Results" VerticalScrollBarVisibility="Auto" Margin="24,0,16,10">
      <StackPanel Margin="0,0,8,0">
        <TextBlock Name="Empty" Foreground="{DynamicResource MutedBrush}" Margin="0,24" TextWrapping="Wrap"/>
        <StackPanel Name="Rows"/>
      </StackPanel>
    </ScrollViewer>
  </DockPanel>
</Window>
'@
    $dialog = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
    $dialog.Owner = $Owner
    $dialog.Icon = $Owner.Icon
    $dialog.Resources.MergedDictionaries.Add($Owner.Resources)
    $panel = $dialog.FindName('Rows')
    $status = $dialog.FindName('ScanStatus')
    $problem = $dialog.FindName('Problem')
    $search = $dialog.FindName('Search')
    $selectedFilter = $dialog.FindName('SelectedFilter')
    $newFilter = $dialog.FindName('NewFilter')
    $empty = $dialog.FindName('Empty')
    $selectionTotal = $dialog.FindName('SelectionTotal')
    $categoryFilter = $dialog.FindName('CategoryFilter')
    $categories = @('โปรแกรมทั่วไป', 'โปรแกรม Crack')
    $existing = @($Config.Packages.Apps | Where-Object { $_ })
    $rows = [Collections.Generic.List[object]]::new()

    function Update-AppView {
        $query = $search.Text.Trim()
        $visible = 0
        $selected = 0
        foreach ($item in $rows) {
            $category = if ($item.CategoryPicker) { $item.CategoryPicker.SelectedIndex } else { $item.Category }
            if ($item.Check.IsChecked) { $selected++ }
            if ($item.Settings) {
                $item.Settings.Visibility = if ($item.Check.IsChecked) { 'Visible' } else { 'Collapsed' }
            }
            $show = (-not $selectedFilter.IsChecked -or $item.Check.IsChecked) -and
                (-not $newFilter.IsChecked -or $item.Candidate) -and
                ($categoryFilter.SelectedIndex -in 0, ($category + 1)) -and
                ($item.SearchText.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            $item.Element.Visibility = if ($show) { 'Visible' } else { 'Collapsed' }
            if ($show) { $visible++ }
        }
        $empty.Visibility = if ($visible) { 'Collapsed' } else { 'Visible' }
        $empty.Text = if ($query) { 'ไม่พบโปรแกรมที่ตรงกับคำค้น' }
            elseif ($newFilter.IsChecked) { 'ยังไม่มีไฟล์ติดตั้งใหม่ใน payloads\Apps' }
            elseif ($selectedFilter.IsChecked) { 'ยังไม่ได้เลือกโปรแกรม' }
            else { 'ยังไม่มีรายการโปรแกรม' }
        $selectionTotal.Text = "เลือก $selected จาก $($rows.Count) รายการ"
    }

    function Add-AppRow($Entry, $Candidate, $Draft) {
        $card = [Windows.Controls.Border]::new()
        $card.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'Card')
        $card.CornerRadius = [Windows.CornerRadius]::new(10)
        $card.Padding = [Windows.Thickness]::new(12, 9, 12, 9)
        $card.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
        $row = [Windows.Controls.StackPanel]::new()
        $card.Child = $row
        $check = [Windows.Controls.CheckBox]::new()
        $check.VerticalContentAlignment = 'Top'
        $check.HorizontalAlignment = 'Stretch'
        $check.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, 'TextBrush')
        $category = [int]($Entry.Category -eq 'Crack')
        if ($Entry) {
            $title = $Entry.Name
            $relativePath = if ($Entry.Subfolder) { Join-Path $Entry.Subfolder $Entry.File } else { $Entry.File }
            $check.IsChecked = $Entry.Enabled -ne $false
        } elseif ($Draft) {
            $title = $Draft.Name
            $relativePath = $Draft.File.Name
            $category = $Draft.Category
            $check.IsChecked = $true
        } else {
            $relativePath = if ($Candidate.Subfolder) {
                Join-Path $Candidate.Subfolder $Candidate.File.Name
            } else { $Candidate.File.Name }
            $title = $Candidate.File.BaseName
        }
        $label = [Windows.Controls.StackPanel]::new()
        $name = [Windows.Controls.TextBlock]::new()
        $name.Text = $title
        $name.TextWrapping = 'Wrap'
        $name.FontWeight = [Windows.FontWeights]::SemiBold
        [void]$label.Children.Add($name)
        $fileLabel = [Windows.Controls.TextBlock]::new()
        $fileLabel.Text = if ($Draft) { "$($categories[$category]) · $relativePath · $($Draft.Steps.Count) ขั้นตอน" }
            elseif ($Candidate) { "ไฟล์ใหม่ · $relativePath" }
            else { "$($categories[$category]) · $relativePath" }
        $fileLabel.FontSize = 12
        $fileLabel.TextWrapping = 'Wrap'
        $fileLabel.Margin = [Windows.Thickness]::new(0, 3, 0, 0)
        $fileLabel.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($Candidate) { 'AccentBrush' } else { 'MutedBrush' }))
        [void]$label.Children.Add($fileLabel)
        $check.Content = $label
        [Windows.Automation.AutomationProperties]::SetName($check, $title)
        [void]$row.Children.Add($check)
        $arguments = $null
        $installedName = $null
        $settings = $null
        $categoryPicker = $null
        if ($Candidate -and -not $Draft) {
            $settings = [Windows.Controls.StackPanel]::new()
            $settings.Margin = [Windows.Thickness]::new(22, 8, 0, 0)
            [void]$row.Children.Add($settings)
            $categoryPicker = [Windows.Controls.ComboBox]::new()
            [Windows.Automation.AutomationProperties]::SetName($categoryPicker, 'หมวดโปรแกรม')
            $categoryPicker.ItemsSource = $categories
            $categoryPicker.SelectedIndex = 0
            $categoryPicker.Margin = [Windows.Thickness]::new(0, 0, 0, 8)
            [void]$settings.Children.Add($categoryPicker)
            if ($Candidate.File.Extension -eq '.exe') {
                $hint = [Windows.Controls.TextBlock]::new()
                $hint.Text = 'พารามิเตอร์ติดตั้งแบบเงียบตามคู่มือผู้ผลิต'
                [void]$settings.Children.Add($hint)
                $arguments = [Windows.Controls.TextBox]::new()
                [Windows.Automation.AutomationProperties]::SetName($arguments, $hint.Text)
                [void]$settings.Children.Add($arguments)
            }
            $hint = [Windows.Controls.TextBlock]::new()
            $hint.Text = 'ชื่อใน Installed apps สำหรับตรวจว่าติดตั้งแล้ว (ถ้าเว้นว่างอาจรันซ้ำ)'
            $hint.TextWrapping = 'Wrap'
            $hint.Margin = [Windows.Thickness]::new(0, 5, 0, 0)
            [void]$settings.Children.Add($hint)
            $installedName = [Windows.Controls.TextBox]::new()
            [Windows.Automation.AutomationProperties]::SetName($installedName, $hint.Text)
            [void]$settings.Children.Add($installedName)
        }
        [void]$panel.Children.Add($card)
        $rows.Add([pscustomobject]@{
            Entry = $Entry; Candidate = $Candidate; Check = $check
            Category = $category; CategoryPicker = $categoryPicker; Draft = $Draft
            Arguments = $arguments; InstalledName = $installedName; Element = $card
            Settings = $settings; SearchText = "$title $relativePath"
        })
        $check.Add_Checked({ Update-AppView })
        $check.Add_Unchecked({ Update-AppView })
        if ($categoryPicker) { $categoryPicker.Add_SelectionChanged({ Update-AppView }) }
    }

    function Update-NewAppRows {
        $candidates = @(Find-NewAppInstallers $AppsPath $existing)
        $paths = @($candidates | ForEach-Object { $_.File.FullName })
        foreach ($stale in @($rows | Where-Object { $_.Candidate -and -not $_.Draft -and $_.Candidate.File.FullName -notin $paths })) {
            $panel.Children.Remove($stale.Element)
            [void]$rows.Remove($stale)
        }
        foreach ($candidate in $candidates) {
            if (-not ($rows | Where-Object { $_.Candidate.File.FullName -eq $candidate.File.FullName })) {
                Add-AppRow $null $candidate
            }
        }
        $status.Text = "พบไฟล์ติดตั้งใหม่ $($candidates.Count) รายการ"
        Update-AppView
    }

    foreach ($entry in $existing) { Add-AppRow $entry $null }
    Update-NewAppRows
    $search.Add_TextChanged({ Update-AppView })
    $categoryFilter.Add_SelectionChanged({ Update-AppView })
    foreach ($filter in 'AllFilter','SelectedFilter','NewFilter') {
        $dialog.FindName($filter).Add_Checked({ Update-AppView })
    }
    $dialog.FindName('Scan').Add_Click({
        try { Update-NewAppRows; $problem.Text = '' } catch { $problem.Text = $_.Exception.Message }
    })
    $dialog.FindName('Browse').Add_Click({
        try {
            $draft = Show-AppRecipeEditor $dialog
            if (-not $draft) { return }
            $dialog.FindName('AllFilter').IsChecked = $true
            $categoryFilter.SelectedIndex = 0
            $search.Clear()
            Add-AppRow $null ([pscustomobject]@{ File = $draft.File; Subfolder = '' }) $draft
            $problem.Text = ''
            Update-AppView
            $dialog.FindName('Results').ScrollToEnd()
        } catch { $problem.Text = $_.Exception.Message; Update-AppView }
    })
    $result = @{ Config = $null }
    $dialog.FindName('Save').Add_Click({
        try {
            $imports = [Collections.Generic.List[object]]::new()
            $updated = $Config | ConvertTo-Json -Depth 100 | ConvertFrom-Json
            $pending = @($rows | Where-Object { $_.Draft -or ($_.Candidate -and $_.Check.IsChecked) })
            $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($configured in $existing) { [void]$names.Add([string]$configured.Name) }
            $available = @(Find-NewAppInstallers $AppsPath $existing | ForEach-Object { $_.File.FullName })
            $newEntries = @(foreach ($row in $pending) {
                $file = $row.Candidate.File
                if ($row.Draft) {
                    $draft = $row.Draft
                    if (-not $names.Add($draft.Name)) { throw "มีโปรแกรมชื่อ $($draft.Name) ในรายการแล้ว" }
                    $subfolder = [guid]::NewGuid().ToString('N')
                    $folder = Join-Path $AppsPath $subfolder
                    foreach ($source in $draft.Sources.GetEnumerator()) {
                        $imports.Add(@{ Source = $source.Value; Name = $source.Key; Folder = $folder })
                    }
                    $entry = [ordered]@{
                        Name = $draft.Name; File = [Management.Automation.WildcardPattern]::Escape($file.Name)
                        Arguments = $draft.Arguments; Subfolder = $subfolder; InstallMode = $draft.Mode
                        Steps = $draft.Steps; Enabled = [bool]$row.Check.IsChecked
                    }
                    if ($draft.Category -eq 1) { $entry.Category = 'Crack' }
                    if ($draft.Reinstall) { $entry.Reinstall = $true }
                    if ($draft.DetectName) { $entry.DetectName = '^' + [regex]::Escape($draft.DetectName) + '$' }
                    [pscustomobject]$entry
                    continue
                }
                if ($file.FullName -notin $available) { throw "ไม่พบไฟล์ $($file.Name) กรุณากดตรวจหาไฟล์ใหม่" }
                $arguments = if ($row.Arguments) { $row.Arguments.Text.Trim() } else { '' }
                if ($file.Extension -eq '.exe' -and -not $arguments) {
                    $dialog.FindName('AllFilter').IsChecked = $true
                    $categoryFilter.SelectedIndex = 0
                    $search.Clear()
                    $row.Arguments.BringIntoView()
                    [void]$row.Arguments.Focus()
                    throw "ระบุพารามิเตอร์ติดตั้งแบบเงียบของ $($file.Name)"
                }
                $name = $row.InstalledName.Text.Trim()
                $newEntry = [ordered]@{
                    Name = if ($name) { $name } else { $file.BaseName }
                    File = [Management.Automation.WildcardPattern]::Escape($file.Name)
                    Arguments = $arguments
                    Enabled = $true
                }
                if (-not $names.Add($newEntry.Name)) { throw "มีโปรแกรมชื่อ $($newEntry.Name) ในรายการแล้ว" }
                if ($name) { $newEntry.DetectName = '^' + [regex]::Escape($name) + '$' }
                if ($row.CategoryPicker.SelectedIndex -eq 1) { $newEntry.Category = 'Crack' }
                if ($row.Candidate.Subfolder) { $newEntry.Subfolder = $row.Candidate.Subfolder }
                [pscustomobject]$newEntry
            })
            $configuredRows = @($rows | Where-Object Entry)
            $configuredEntries = @($updated.Packages.Apps | Where-Object { $_ })
            $updated.Packages.Apps = @(for ($i = 0; $i -lt $configuredRows.Count; $i++) {
                $entry = $configuredEntries[$i]
                $entry | Add-Member -NotePropertyName Enabled -NotePropertyValue ([bool]$configuredRows[$i].Check.IsChecked) -Force
                $entry
            }) + $newEntries

            $temporary = $ConfigPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            $created = [Collections.Generic.List[string]]::new()
            $saved = $false
            try {
                if ($imports.Count) {
                    foreach ($folder in (Split-Path -Parent $AppsPath), $AppsPath) {
                        $item = Get-Item -LiteralPath $folder -ErrorAction SilentlyContinue
                        if ($item -and (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
                            throw "ไม่รองรับโฟลเดอร์ $folder"
                        }
                    }
                }
                foreach ($import in $imports) {
                    $file = Get-Item -LiteralPath $import.Source
                    if ($file.PSIsContainer -or $file.Length -le 0 -or ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                        throw "ไม่รองรับไฟล์ $($file.Name)"
                    }
                    [void][IO.Directory]::CreateDirectory($import.Folder)
                    if (-not $created.Contains($import.Folder)) { $created.Add($import.Folder) }
                    [IO.File]::Copy($import.Source, (Join-Path $import.Folder $import.Name))
                }
                [IO.File]::WriteAllText($temporary, ($updated | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
                [IO.File]::Replace($temporary, $ConfigPath, [NullString]::Value)
                $saved = $true
            } finally {
                [IO.File]::Delete($temporary)
                if (-not $saved) {
                    foreach ($folder in $created) { [IO.Directory]::Delete($folder, $true) }
                }
            }
            $result.Config = $updated
            $dialog.DialogResult = $true
        } catch {
            $problem.Text = $_.Exception.Message
        }
    })
    if ($dialog.ShowDialog() -eq $true) { $result.Config }
}
