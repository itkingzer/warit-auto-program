# บังคับสิทธิ์ผู้ดูแลระบบ และใช้ STA สำหรับ WPF
param([switch]$ResumeOnly, [switch]$StartupLaunch, [switch]$AutoInstall)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$StatePath = Join-Path $Root state.json
function Test-UpdateOwnsStartup {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $false }
    $startupState = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($startupState.Mode -eq 'UpdateLoop') { return $true }
    if (-not $startupState.UpdateBoot) { return $false }
    $boot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    return $startupState.UpdateBoot -eq $boot.ToUniversalTime().Ticks.ToString()
}
if ($StartupLaunch -and -not $ResumeOnly -and (Test-UpdateOwnsStartup)) { return }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $exe = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
}
$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -or $exe -like '*Sysnative*') {
    $launch = @{
        FilePath = $exe
        ArgumentList = '-NoProfile -STA -ExecutionPolicy RemoteSigned -File "{0}"' -f $PSCommandPath
        WorkingDirectory = $Root
        WindowStyle = 'Hidden'
    }
    if ($ResumeOnly) { $launch.ArgumentList += ' -ResumeOnly' }
    if ($StartupLaunch) { $launch.ArgumentList += ' -StartupLaunch' }
    if ($AutoInstall) { $launch.ArgumentList += ' -AutoInstall' }
    if (-not $admin) { $launch.Verb = 'RunAs' }
    Start-Process @launch
    return
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$windowTitle = 'Warit · Windows Auto Setup'
$mutex = [Threading.Mutex]::new($false, 'Global\WaritAutoSetup')
try { $locked = $mutex.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $locked = $true }
if (-not $locked) {
    $mutex.Dispose()
    if (-not $StartupLaunch -or $ResumeOnly) {
        $existing = Get-Process -Name powershell,pwsh -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -eq $windowTitle } | Select-Object -First 1
        if ($existing) {
            Add-Type -Namespace Warit -Name SetupWindow -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
'@
            $handle = $existing.MainWindowHandle
            if ([Warit.SetupWindow]::IsIconic($handle)) { [void][Warit.SetupWindow]::ShowWindowAsync($handle, 9) }
            $shell = New-Object -ComObject WScript.Shell
            if ($shell.AppActivate($existing.Id)) { return }
        }
        [void][Windows.MessageBox]::Show('Auto Setup กำลังทำงานอยู่ เปิดหน้าต่างเดิมจากแถบงานหรือกด Alt+Tab', 'Windows Auto Setup')
    }
    return
}
try {
if ($StartupLaunch -and -not $ResumeOnly -and (Test-UpdateOwnsStartup)) { return }
$ResumeTask = 'WaritAutoSetup-WindowsUpdateResume'
$resume = $false
$resumeAutoRestart = $false
if (Test-Path -LiteralPath $StatePath) {
    $updateState = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $mode = $updateState.Mode
    if ($mode -notin 'Idle','UpdateLoop') { throw "state.json มี Mode ที่ไม่รองรับ: $mode" }
    $resume = $mode -eq 'UpdateLoop'
    $resumeAutoRestart = $resume -and $updateState.AutoRestart -eq $true
}
if ($ResumeOnly -and -not $resume) { return }
$configPath = Join-Path $Root 'config.json'
$Config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$Config.InstallerTimeoutSeconds -lt 1) { throw 'InstallerTimeoutSeconds ต้องมากกว่า 0' }
$logDir = Join-Path $Root logs
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$PayloadFolders = @{
    Printer = '+แก้ Code Error Printer'; Runtimes = 'Runtimes'; Apps = 'Apps'; LINE = 'LINE'
    Foxit = '++Foxit PDF Editor Pro'; ACDSee = '++ACDSee Photo Studio Ultimate'; Office = 'Office'
}
$choices = [ordered]@{
    Disk = @('แบ่งดิสก์และคัดลอกไฟล์ลูกค้า', $false)
    System = @('Desktop, ภาษา และเวลา', $true)
    GraveAccent = @('สลับภาษาด้วยปุ่ม ` (Grave Accent)', $false)
    SMB = @('เปิด SMB 2/3 สำหรับเครือข่ายส่วนตัว', $false)
    Printer = @('แก้ Printer Error 709 (GPEDIT, RPC และ SMB signing)', $false)
    Fonts = @('ฟอนต์', $true)
    Runtimes = @('Runtimes', $true)
    Apps = @('โปรแกรมทั่วไป', $true)
    Foxit = @('FOXIT PDF Editor Pro', $false)
    ACDSee = @('ACDSee Photo Studio Ultimate', $false)
    LINE = @('LINE (ติดตั้งเงียบผ่าน WinGet · ใช้อินเทอร์เน็ต)', $false)
    Office = @('Office 2024 ProPlus Retail', $false)
    Drivers = @('ค้นหาและติดตั้งไดรเวอร์จาก Windows Update', $false)
    Update = @('Windows Update', $true)
}
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Warit · Windows Auto Setup" Width="1190" Height="790" MinWidth="800" MinHeight="460"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="14" UseLayoutRounding="True" SnapsToDevicePixels="True">
  <Window.Resources>
    <SolidColorBrush x:Key="CanvasBrush" Color="#101113"/>
    <SolidColorBrush x:Key="SurfaceBrush" Color="#1B1D21"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F6F4F0"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#B9BBC2"/>
    <SolidColorBrush x:Key="DisabledTextBrush" Color="#8E919A"/>
    <SolidColorBrush x:Key="LineBrush" Color="#383B43"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#FFB270"/>
    <SolidColorBrush x:Key="OnAccentBrush" Color="#261509"/>
    <SolidColorBrush x:Key="SoftBrush" Color="#382B24"/>
    <SolidColorBrush x:Key="ConsoleBrush" Color="#141519"/>
    <SolidColorBrush x:Key="ConsoleTextBrush" Color="#E7E4E0"/>
    <LinearGradientBrush x:Key="HeroBrush" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#30241E" Offset="0"/>
      <GradientStop Color="#1B1D21" Offset="0.65"/>
    </LinearGradientBrush>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="16"/>
      <Setter Property="Padding" Value="18"/>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Padding" Value="11,7"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Option" Background="Transparent" CornerRadius="5" Padding="{TemplateBinding Padding}" Margin="1">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="18"/>
                </Grid.ColumnDefinitions>
                <ContentPresenter VerticalAlignment="Center"/>
                <Path x:Name="Checkmark" Grid.Column="1" Data="M 0,4 L 3,7 L 9,0" StrokeThickness="1.5"
                      Stroke="{DynamicResource AccentBrush}" Visibility="Collapsed"
                      HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Checkmark" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Option" Property="Background" Value="{DynamicResource SoftBrush}"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Option" Property="Background" Value="{DynamicResource LineBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="{DynamicResource ConsoleBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="MinHeight" Value="36"/>
      <Setter Property="MaxDropDownHeight" Value="260"/>
      <Setter Property="Padding" Value="11,5,34,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid x:Name="Field" SnapsToDevicePixels="True">
              <ToggleButton x:Name="OpenMenu" Focusable="False" FocusVisualStyle="{x:Null}" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="Transparent"/>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Border x:Name="Outline" IsHitTestVisible="False" Background="{TemplateBinding Background}"
                      BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="7"/>
              <ContentPresenter Content="{TemplateBinding SelectionBoxItem}" ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                ContentTemplateSelector="{TemplateBinding ItemTemplateSelector}"
                                Margin="{TemplateBinding Padding}" VerticalAlignment="Center" IsHitTestVisible="False"/>
              <Path x:Name="Chevron" Data="M 0,0 L 4,4 L 8,0" StrokeThickness="1.5" Stroke="{DynamicResource MutedBrush}"
                    HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,13,0"
                    IsHitTestVisible="False"/>
              <Popup x:Name="PART_Popup" Placement="Bottom" PlacementTarget="{Binding ElementName=Field}"
                     IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" VerticalOffset="4">
                <Border MinWidth="{Binding ActualWidth, ElementName=Field}" MaxHeight="{TemplateBinding MaxDropDownHeight}"
                        Background="{DynamicResource SurfaceBrush}" BorderBrush="{DynamicResource LineBrush}"
                        BorderThickness="1" CornerRadius="8" Padding="4">
                  <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                    <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Contained"/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Outline" Property="Background" Value="{DynamicResource SurfaceBrush}"/>
              </Trigger>
              <Trigger Property="IsKeyboardFocusWithin" Value="True">
                <Setter TargetName="Outline" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsDropDownOpen" Value="True">
                <Setter TargetName="Outline" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="Chevron" Property="Data" Value="M 0,4 L 4,0 L 8,4"/>
                <Setter TargetName="Chevron" Property="Stroke" Value="{DynamicResource AccentBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
                <Setter TargetName="Chevron" Property="Stroke" Value="{DynamicResource DisabledTextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Heading" TargetType="TextBlock">
      <Setter Property="FontSize" Value="19"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="TaskGroup" TargetType="Border" BasedOn="{StaticResource Card}">
      <Setter Property="Background" Value="{DynamicResource ConsoleBrush}"/>
      <Setter Property="CornerRadius" Value="12"/>
      <Setter Property="Padding" Value="8"/>
      <Setter Property="Margin" Value="0,0,6,8"/>
    </Style>
    <Style x:Key="PhaseBadge" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource SoftBrush}"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="7,3"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
    <Style x:Key="Section" TargetType="TextBlock">
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
      <Setter Property="Margin" Value="0,14,0,5"/>
    </Style>
    <Style x:Key="Eyebrow" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="Background" Value="{DynamicResource SurfaceBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="MinHeight" Value="38"/>
      <Setter Property="Padding" Value="12,5"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Frame" CornerRadius="9" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" RecognizesAccessKey="True"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Frame" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Frame" Property="Opacity" Value="0.82"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Frame" Property="BorderBrush" Value="{DynamicResource MutedBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
                <Setter TargetName="Frame" Property="Background" Value="{DynamicResource ConsoleBrush}"/>
                <Setter TargetName="Frame" Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource AccentBrush}"/>
      <Setter Property="Foreground" Value="{DynamicResource OnAccentBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
    </Style>
    <Style x:Key="DrawerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Padding" Value="10,5"/>
      <Setter Property="Margin" Value="0,2"/>
      <Style.Triggers>
        <Trigger Property="Tag" Value="Selected">
          <Setter Property="Background" Value="{DynamicResource SoftBrush}"/>
          <Setter Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
          <Setter Property="Foreground" Value="{DynamicResource AccentBrush}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="QuietButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{DynamicResource MutedBrush}"/>
    </Style>
    <Style x:Key="NavIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Width" Value="23"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
      <Setter Property="MinHeight" Value="38"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="TaskRow" Background="Transparent" BorderBrush="Transparent" BorderThickness="1" CornerRadius="8" Padding="10,6">
              <DockPanel>
                <Border x:Name="CheckMark" DockPanel.Dock="Left" Width="18" Height="18" Margin="0,0,10,0" VerticalAlignment="Center" CornerRadius="5" BorderThickness="1" BorderBrush="{DynamicResource MutedBrush}">
                  <TextBlock x:Name="Tick" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="{DynamicResource OnAccentBrush}" Visibility="Hidden"/>
                </Border>
                <ContentPresenter VerticalAlignment="Center"/>
              </DockPanel>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="TaskRow" Property="Background" Value="{DynamicResource SoftBrush}"/>
                <Setter TargetName="TaskRow" Property="BorderBrush" Value="{DynamicResource LineBrush}"/>
                <Setter TargetName="CheckMark" Property="Background" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="CheckMark" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="TaskRow" Property="BorderBrush" Value="{DynamicResource AccentBrush}"/></Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="TaskRow" Property="BorderBrush" Value="{DynamicResource MutedBrush}"/></Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{DynamicResource DisabledTextBrush}"/>
                <Setter TargetName="TaskRow" Property="Opacity" Value="0.75"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Background="{DynamicResource CanvasBrush}" TextElement.Foreground="{DynamicResource TextBrush}">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
    <Border Name="AntivirusAlert" Visibility="Collapsed" Background="#A61B29" Padding="18,9">
      <TextBlock Name="AntivirusAlertText" Foreground="White" FontWeight="SemiBold"
                 TextAlignment="Center" TextWrapping="Wrap" AutomationProperties.LiveSetting="Polite"/>
    </Border>
    <Grid Grid.Row="1" Margin="20,16">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Border Style="{StaticResource Card}" Background="{DynamicResource HeroBrush}" Padding="18,12" Margin="0,0,0,12">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="16,0,0,0">
            <TextBlock Text="จัดทำโดย @warit ophang" Foreground="{DynamicResource MutedBrush}" FontSize="12" VerticalAlignment="Center" Margin="0,0,12,0"/>
            <Button Name="RestartButton" Style="{StaticResource QuietButton}" AutomationProperties.Name="รีสตาร์ทเครื่อง">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xE72C;"/><TextBlock Text="รีสตาร์ทเครื่อง"/></StackPanel>
            </Button>
          </StackPanel>
          <Border DockPanel.Dock="Left" CornerRadius="13" Width="54" Height="54" BorderThickness="1" BorderBrush="{DynamicResource AccentBrush}" Margin="0,0,14,0" VerticalAlignment="Center">
            <Border.Background><ImageBrush x:Name="AppLogo" Stretch="UniformToFill"/></Border.Background>
          </Border>
          <StackPanel>
            <TextBlock Text="WARIT / WORKSPACE" Style="{StaticResource Eyebrow}"/>
            <TextBlock Text="Windows Auto Setup" FontSize="28" FontWeight="SemiBold" Margin="0,2,0,1"/>
            <TextBlock Text="ตั้งค่า ติดตั้ง และตรวจข้อมูลเครื่องในที่เดียว" Foreground="{DynamicResource MutedBrush}" FontSize="13"/>
          </StackPanel>
        </DockPanel>
      </Border>
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions><ColumnDefinition Width="166"/><ColumnDefinition Width="*"/><ColumnDefinition Name="DrawerColumn" Width="1.15*" MinWidth="320"/></Grid.ColumnDefinitions>
        <Border Style="{StaticResource Card}" Padding="10,14" Background="{DynamicResource ConsoleBrush}">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
            <StackPanel>
              <TextBlock Text="ข้อมูลเครื่อง" Style="{StaticResource Eyebrow}" Foreground="{DynamicResource MutedBrush}" Margin="10,4,0,8"/>
              <Button Name="SpecsNav" Style="{StaticResource DrawerButton}" AutomationProperties.Name="สเปกเครื่อง">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xE7F4;"/><TextBlock Text="สเปกเครื่อง"/></StackPanel>
              </Button>
              <Button Name="LicenseNav" Style="{StaticResource DrawerButton}" AutomationProperties.Name="การเปิดใช้งาน Office และ Windows">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xE72E;"/><TextBlock Text="การเปิดใช้งาน"/></StackPanel>
              </Button>
              <Button Name="DriversNav" Style="{StaticResource DrawerButton}" AutomationProperties.Name="ไดรเวอร์">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xE950;"/><TextBlock Text="ไดรเวอร์"/></StackPanel>
              </Button>
              <Button Name="ProgramsNav" Style="{StaticResource DrawerButton}" AutomationProperties.Name="โปรแกรม">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xE71D;"/><TextBlock Text="โปรแกรม"/></StackPanel>
              </Button>
              <Button Name="AntivirusNav" Style="{StaticResource DrawerButton}" AutomationProperties.Name="แอนติไวรัส">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xEA18;"/><TextBlock Text="แอนติไวรัส"/></StackPanel>
              </Button>
              <Border Height="1" Background="{DynamicResource LineBrush}" Margin="8,10"/>
              <TextBlock Text="กิจกรรม" Style="{StaticResource Eyebrow}" Foreground="{DynamicResource MutedBrush}" Margin="10,0,0,8"/>
              <Button Name="LogNav" Style="{StaticResource DrawerButton}" AutomationProperties.Name="บันทึกการทำงาน">
                <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xE9D5;"/><TextBlock Text="บันทึกงาน"/></StackPanel>
              </Button>
            </StackPanel>
          </ScrollViewer>
        </Border>
        <Border Grid.Column="1" Style="{StaticResource Card}" Margin="12,0,0,0" Padding="18,10">
          <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel>
              <StackPanel Margin="0,0,0,6">
                <DockPanel Margin="0,0,0,6">
                  <Border DockPanel.Dock="Right" CornerRadius="8" Background="{DynamicResource SoftBrush}" Padding="8,4" Margin="8,0,0,0">
                    <TextBlock Name="SelectionCount" Foreground="{DynamicResource AccentBrush}" FontSize="12" FontWeight="SemiBold" AutomationProperties.LiveSetting="Polite"/>
                  </Border>
                  <TextBlock Text="เลือกงาน" FontSize="16" FontWeight="SemiBold" VerticalAlignment="Center" TextWrapping="Wrap"/>
                </DockPanel>
                <WrapPanel Name="QuickActions">
                  <Button Name="AppsOnlyButton" MinHeight="34" Content="โปรแกรมทั่วไป" ToolTip="เลือกรายการและตรวจหาไฟล์ติดตั้งใหม่" Margin="0,0,8,3"/>
                  <Button Name="CheckPayload" MinHeight="34" Content="ตรวจ Payload" Margin="0,0,8,3"/>
                  <Button Name="ClearButton" Style="{StaticResource QuietButton}" MinHeight="34" Content="ล้าง" ToolTip="ล้างงานที่เลือก" AutomationProperties.Name="ล้างงานที่เลือก" Margin="0,0,0,3"/>
                </WrapPanel>
              </StackPanel>
              <StackPanel Name="Options" KeyboardNavigation.TabNavigation="Continue"/>
            </StackPanel>
          </ScrollViewer>
        </Border>
        <Border Name="DetailsDrawer" Grid.Column="2" Style="{StaticResource Card}" Margin="12,0,0,0">
          <DockPanel>
            <Border DockPanel.Dock="Top" BorderBrush="{DynamicResource LineBrush}" BorderThickness="0,0,0,1" Padding="0,0,0,12" Margin="0,0,0,14">
              <DockPanel>
                <Button Name="CloseDrawer" DockPanel.Dock="Right" Style="{StaticResource QuietButton}" Width="38" Padding="0" ToolTip="ปิดแผงข้อมูล (Esc)" AutomationProperties.Name="ปิดแผงข้อมูล">
                  <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xE711;"/>
                </Button>
                <StackPanel VerticalAlignment="Center">
                  <TextBlock Text="รายละเอียด" Style="{StaticResource Eyebrow}"/>
                  <TextBlock Name="DrawerTitle" Style="{StaticResource Heading}" Margin="0,3,0,0"/>
                </StackPanel>
              </DockPanel>
            </Border>
            <TabControl Name="DetailsTabs" Focusable="False">
              <TabControl.Resources>
                <Style TargetType="TabItem">
                  <Setter Property="Foreground" Value="{DynamicResource TextBrush}"/>
                </Style>
              </TabControl.Resources>
              <TabControl.Template>
                <ControlTemplate TargetType="TabControl">
                  <ContentPresenter x:Name="PART_SelectedContentHost" ContentSource="SelectedContent"/>
                </ControlTemplate>
              </TabControl.Template>
              <TabItem Header="สเปกเครื่อง">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel>
                    <TextBlock Name="SpecsText" Text="ยังไม่ได้อ่านสเปก" TextWrapping="Wrap"/>
                    <StackPanel Name="SpecsDetails" Visibility="Collapsed">
                      <Border Style="{StaticResource Card}" Background="{DynamicResource SoftBrush}" Padding="12" Margin="0,0,0,4">
                        <StackPanel>
                          <TextBlock Text="เครื่องนี้" Style="{StaticResource Eyebrow}"/>
                          <TextBlock Text="{Binding Model}" Style="{StaticResource Heading}" TextWrapping="Wrap"/>
                          <TextBlock Text="{Binding Windows}" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
                        </StackPanel>
                      </Border>
                      <TextBlock Text="โปรเซสเซอร์ (CPU)" Style="{StaticResource Section}"/>
                      <TextBlock Text="{Binding CPU}" TextWrapping="Wrap"/>
                      <TextBlock Text="หน่วยความจำ (RAM)" Style="{StaticResource Section}"/>
                      <TextBlock Text="{Binding RAM}" TextWrapping="Wrap"/>
                      <TextBlock Text="กราฟิก (GPU)" Style="{StaticResource Section}"/>
                      <TextBlock Text="{Binding GPU}" TextWrapping="Wrap"/>
                      <TextBlock Text="พื้นที่จัดเก็บ" Style="{StaticResource Section}"/>
                      <TextBlock Text="{Binding Storage}" TextWrapping="Wrap"/>
                    </StackPanel>
                  </StackPanel>
                </ScrollViewer>
              </TabItem>
              <TabItem Header="การเปิดใช้งาน">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <StackPanel>
                    <Button Name="RefreshLicense" Content="ตรวจสถานะ Office และ Windows" HorizontalAlignment="Left" Margin="0,0,0,12"/>
                    <TextBlock Text="Office Professional Plus 2024 Retail" Style="{StaticResource Section}" TextWrapping="Wrap"/>
                    <Border Style="{StaticResource Card}" Background="{DynamicResource SoftBrush}" Padding="12">
                      <TextBlock Name="OfficeLicenseSummary" Text="กดตรวจสถานะเพื่อดูข้อมูล Office" TextWrapping="Wrap" LineHeight="23"/>
                    </Border>
                    <TextBlock Text="ติดตั้งรุ่น 64 บิต ภาษาไทยจาก Microsoft เปิดใช้งานในแอป Office ด้วยสิทธิ์ Retail ที่ตรงรุ่น" Margin="0,10,0,8" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
                    <Button Name="InstallOffice" Content="ดาวน์โหลดและติดตั้ง Office" HorizontalAlignment="Left" Margin="0,0,8,6" IsEnabled="False"/>
                    <TextBlock Text="Windows" Style="{StaticResource Section}"/>
                    <Border Style="{StaticResource Card}" Background="{DynamicResource SoftBrush}" Padding="12">
                      <TextBlock Name="LicenseSummary" Text="กดตรวจสถานะเพื่อดูข้อมูลสิทธิ์" TextWrapping="Wrap" LineHeight="23"/>
                    </Border>
                    <TextBlock Text="ผลตรวจในเครื่องไม่ใช่หลักฐานการซื้อสิทธิ์ คีย์ OEM ในเฟิร์มแวร์อาจเป็นของ Windows คนละรุ่นกับที่ติดตั้ง" Margin="0,10,0,12" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
                    <WrapPanel>
                      <Button Name="ActivationSettings" Content="เปิดใช้งาน Windows ใน Settings" Margin="0,0,8,6"/>
                    </WrapPanel>
                    <StackPanel Name="Extras">
                      <TextBlock Text="เครื่องมือเสริม (TOOL)" Style="{StaticResource Section}"/>
                      <WrapPanel>
                        <Button Name="ActivateMas" Content="ACTIVATE MAS" Margin="0,0,8,6"/>
                        <Button Name="OpenOfficeInstaller" Content="OfficeInstall++" Margin="0,0,8,6"/>
                        <Button Name="OpenOfficeTool" Content="Office Tool Plus" Margin="0,0,0,6"/>
                      </WrapPanel>
                    </StackPanel>
                  </StackPanel>
                </ScrollViewer>
              </TabItem>
              <TabItem Header="ไดรเวอร์">
                <DockPanel>
                  <Button Name="ScanDrivers" DockPanel.Dock="Top" HorizontalAlignment="Left" Content="ตรวจไดรเวอร์"/>
                  <TextBlock Name="DriverSummary" DockPanel.Dock="Top" Margin="0,9" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"
                             Text="ปุ่มนี้ตรวจอย่างเดียว ไม่ติดตั้ง หากต้องการติดตั้ง ให้เลือกงานไดรเวอร์ในแผนการตั้งค่า"/>
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel>
                      <TextBlock Text="อุปกรณ์ที่ยังไม่มีไดรเวอร์" Style="{StaticResource Section}"/>
                      <TextBlock Name="MissingDrivers" Text="ยังไม่ได้ตรวจ" TextWrapping="Wrap"/>
                      <TextBlock Text="รายการจาก Windows Update" Style="{StaticResource Section}"/>
                      <TextBlock Name="AvailableDrivers" Text="ยังไม่ได้ตรวจ" TextWrapping="Wrap"/>
                    </StackPanel>
                  </ScrollViewer>
                </DockPanel>
              </TabItem>
              <TabItem Header="โปรแกรม">
                <DockPanel>
                  <Button Name="RefreshInventory" DockPanel.Dock="Top" HorizontalAlignment="Left" Content="ตรวจรายการใหม่"/>
                  <TextBlock Name="InventorySummary" DockPanel.Dock="Top" Margin="0,8" Text="ยังไม่ได้ตรวจโปรแกรม" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
                  <ScrollViewer Name="PayloadReportPane" DockPanel.Dock="Top" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
                    <TextBlock Name="PayloadReport" TextWrapping="Wrap" Margin="0,0,12,0"/>
                  </ScrollViewer>
                  <ListBox Name="InventoryList" AutomationProperties.Name="สถานะโปรแกรม" BorderThickness="0"
                           Background="Transparent" Foreground="{DynamicResource TextBrush}"
                           ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.CanContentScroll="True" HorizontalContentAlignment="Stretch">
                    <ListBox.ItemTemplate>
                      <DataTemplate>
                        <Border Style="{StaticResource Card}" Background="{DynamicResource ConsoleBrush}" CornerRadius="8" Padding="10,7" Margin="0,2">
                          <StackPanel TextElement.Foreground="{DynamicResource TextBrush}">
                            <TextBlock Text="{Binding Name}" FontWeight="SemiBold" TextWrapping="Wrap"/>
                            <TextBlock Text="{Binding Status}" Foreground="{DynamicResource AccentBrush}" TextWrapping="Wrap"/>
                            <TextBlock Foreground="{DynamicResource MutedBrush}" TextWrapping="Wrap">
                              <TextBlock.Text>
                                <MultiBinding StringFormat="เวอร์ชัน: {0}  ·  ตัวติดตั้ง: {1}">
                                  <Binding Path="Version"/>
                                  <Binding Path="Payload"/>
                                </MultiBinding>
                              </TextBlock.Text>
                            </TextBlock>
                          </StackPanel>
                        </Border>
                      </DataTemplate>
                    </ListBox.ItemTemplate>
                  </ListBox>
                </DockPanel>
              </TabItem>
              <TabItem Header="แอนติไวรัส">
                <DockPanel>
                  <WrapPanel DockPanel.Dock="Top">
                    <Button Name="RefreshAntivirus" Content="ตรวจสถานะใหม่" Margin="0,0,8,0"/>
                    <Button Name="OpenWindowsSecurity" Content="เปิด Windows Security"/>
                  </WrapPanel>
                  <TextBlock Name="AntivirusSummary" DockPanel.Dock="Top" Margin="0,8" TextWrapping="Wrap"/>
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <TextBlock Name="AntivirusDetails" TextWrapping="Wrap" Margin="0,0,8,0"/>
                  </ScrollViewer>
                </DockPanel>
              </TabItem>
              <TabItem Header="บันทึกการทำงาน">
                <DockPanel>
                  <Button Name="LogsButton" DockPanel.Dock="Top" HorizontalAlignment="Left" Margin="0,0,0,8" Content="เปิดโฟลเดอร์ Log"/>
                  <Border CornerRadius="8" Background="{DynamicResource ConsoleBrush}" Padding="8">
                    <TextBox Name="LogBox" BorderThickness="0" Background="Transparent" Foreground="{DynamicResource ConsoleTextBrush}"
                             AutomationProperties.Name="บันทึกการทำงาน" FontFamily="Consolas, Segoe UI" FontSize="13" Padding="5"
                             IsReadOnly="True" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" TextWrapping="Wrap"/>
                  </Border>
                </DockPanel>
              </TabItem>
            </TabControl>
          </DockPanel>
        </Border>
      </Grid>
      <Border Grid.Row="2" Style="{StaticResource Card}" Padding="14,10" Margin="0,12,0,0">
        <DockPanel>
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0,0,0">
            <Button Name="CancelButton" Content="ยกเลิกงาน" Style="{StaticResource QuietButton}" Margin="0,0,8,0" IsEnabled="False"/>
            <Button Name="StartButton" Style="{StaticResource PrimaryButton}" MinWidth="156" MinHeight="44" AutomationProperties.Name="เริ่มงานที่เลือก">
              <StackPanel Orientation="Horizontal"><TextBlock Style="{StaticResource NavIcon}" Text="&#xE768;"/><TextBlock Text="เริ่มงานที่เลือก"/></StackPanel>
            </Button>
          </StackPanel>
          <StackPanel VerticalAlignment="Center">
            <DockPanel Margin="0,0,0,3">
              <TextBlock Name="ProgressLabel" DockPanel.Dock="Right" Text="0%" Foreground="{DynamicResource AccentBrush}" FontSize="12" FontWeight="SemiBold" Margin="10,0,0,0"/>
              <TextBlock Text="สถานะงาน" Style="{StaticResource Eyebrow}" Foreground="{DynamicResource MutedBrush}"/>
            </DockPanel>
            <TextBlock Name="Status" Text="พร้อมเริ่ม" TextWrapping="Wrap" TextTrimming="WordEllipsis" MaxHeight="40"
                       ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" Margin="0,0,0,7" AutomationProperties.LiveSetting="Polite"/>
            <ProgressBar Name="Progress" Height="6" Minimum="0" Maximum="100"
                         AutomationProperties.Name="ความคืบหน้ารวม" Foreground="{DynamicResource AccentBrush}"
                         Background="{DynamicResource ConsoleBrush}" BorderBrush="{DynamicResource LineBrush}"/>
          </StackPanel>
        </DockPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
"@
Add-Type -Namespace WaritAutoSetup -Name Taskbar -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
'@
$taskbarResult = [WaritAutoSetup.Taskbar]::SetCurrentProcessExplicitAppUserModelID('Warit.AutoSetup')
if ($taskbarResult -lt 0) { [Runtime.InteropServices.Marshal]::ThrowExceptionForHR($taskbarResult) }

$Window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$brandAssets = Join-Path $Root 'assets'
$Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $brandAssets 'app.ico'))
$Window.FindName('AppLogo').ImageSource = [Windows.Media.Imaging.BitmapFrame]::Create([uri](Join-Path $brandAssets 'app-logo.png'))
$controls = @{}
foreach ($name in 'StartButton','CancelButton','RestartButton','LogsButton','Options','Progress','Status','LogBox','ProgressLabel','SelectionCount','QuickActions','AppsOnlyButton','ClearButton','InventorySummary','InventoryList','RefreshInventory','SpecsText','SpecsDetails','LicenseSummary','RefreshLicense','OfficeLicenseSummary','InstallOffice','ActivationSettings','ActivateMas','ScanDrivers','DriverSummary','MissingDrivers','AvailableDrivers','DrawerColumn','DetailsDrawer','DetailsTabs','DrawerTitle','CloseDrawer','SpecsNav','LicenseNav','DriversNav','ProgramsNav','AntivirusNav','RefreshAntivirus','OpenWindowsSecurity','AntivirusSummary','AntivirusDetails','LogNav') {
    $controls[$name] = $Window.FindName($name)
}
$controls.CheckPayload = $Window.FindName('CheckPayload')
$controls.PayloadReportPane = $Window.FindName('PayloadReportPane')
$controls.PayloadReport = $Window.FindName('PayloadReport')
$controls.OpenOfficeInstaller = $Window.FindName('OpenOfficeInstaller')
$controls.OpenOfficeTool = $Window.FindName('OpenOfficeTool')
$controls.AntivirusAlert = $Window.FindName('AntivirusAlert')
$controls.AntivirusAlertText = $Window.FindName('AntivirusAlertText')
$controls.Extras = $Window.FindName('Extras')
$officeToolPath = Join-Path $Root 'payloads\Office Tool\Office Tool Plus.exe'
# ใช้สีระบบเมื่อ Windows เปิดโหมด High Contrast
if ([Windows.SystemParameters]::HighContrast) {
    foreach ($entry in @{
        CanvasBrush = [Windows.SystemColors]::ControlBrush; SurfaceBrush = [Windows.SystemColors]::WindowBrush
        TextBrush = [Windows.SystemColors]::WindowTextBrush; MutedBrush = [Windows.SystemColors]::WindowTextBrush
        DisabledTextBrush = [Windows.SystemColors]::GrayTextBrush
        LineBrush = [Windows.SystemColors]::WindowTextBrush; AccentBrush = [Windows.SystemColors]::HighlightBrush
        OnAccentBrush = [Windows.SystemColors]::HighlightTextBrush; SoftBrush = [Windows.SystemColors]::WindowBrush
        ConsoleBrush = [Windows.SystemColors]::WindowBrush; ConsoleTextBrush = [Windows.SystemColors]::WindowTextBrush
        HeroBrush = [Windows.SystemColors]::WindowBrush
    }.GetEnumerator()) { $Window.Resources[$entry.Key] = $entry.Value }
}
$drawerButtons = @($controls.SpecsNav, $controls.LicenseNav, $controls.DriversNav, $controls.ProgramsNav, $controls.AntivirusNav, $controls.LogNav)
$drawerWidth = $controls.DrawerColumn.Width
$drawerMinWidth = $controls.DrawerColumn.MinWidth

function Update-DrawerNavigation {
    $controls.DrawerTitle.Text = $controls.DetailsTabs.SelectedItem.Header
    for ($index = 0; $index -lt $drawerButtons.Count; $index++) {
        $active = $controls.DetailsDrawer.Visibility -eq 'Visible' -and $index -eq $controls.DetailsTabs.SelectedIndex
        $drawerButtons[$index].Tag = if ($active) { 'Selected' } else { $null }
        [Windows.Automation.AutomationProperties]::SetItemStatus($drawerButtons[$index], $(if ($active) { 'เปิดอยู่' } else { '' }))
    }
}

function Show-DetailsDrawer([Windows.Controls.Button]$Page) {
    $controls.DetailsTabs.SelectedIndex = [Array]::IndexOf($drawerButtons, $Page)
    $controls.DrawerColumn.Width = $drawerWidth
    $controls.DrawerColumn.MinWidth = $drawerMinWidth
    $controls.DetailsDrawer.Visibility = 'Visible'
    Update-DrawerNavigation
}

function Hide-DetailsDrawer {
    if ($controls.DetailsDrawer.IsKeyboardFocusWithin) {
        [void]$drawerButtons[$controls.DetailsTabs.SelectedIndex].Focus()
    }
    $controls.DetailsDrawer.Visibility = 'Collapsed'
    $controls.DrawerColumn.MinWidth = 0
    $controls.DrawerColumn.Width = [Windows.GridLength]::new(0)
    Update-DrawerNavigation
}

foreach ($button in $drawerButtons) {
    $button.Add_Click({
        param($sender, $eventArgs)
        if ($sender.Tag -eq 'Selected') { Hide-DetailsDrawer }
        else {
            Show-DetailsDrawer $sender
            if ($sender -eq $controls.AntivirusNav) { Start-AntivirusScan }
        }
    })
}
$controls.DetailsTabs.Add_SelectionChanged({
    param($sender, $eventArgs)
    if ($eventArgs.Source -eq $sender) { Update-DrawerNavigation }
})
$controls.CloseDrawer.Add_Click({ Hide-DetailsDrawer })
$Window.Add_PreviewKeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -eq 'Escape' -and $controls.DetailsDrawer.Visibility -eq 'Visible') {
        Hide-DetailsDrawer
        $eventArgs.Handled = $true
    }
})
Show-DetailsDrawer $controls.SpecsNav
$sections = @{ Disk = @('01', 'พื้นที่จัดเก็บ'); System = @('02', 'ตั้งค่าและติดตั้ง'); Update = @('03', 'อัปเดต Windows') }
. (Join-Path $Root 'modules\08-AppSelection.ps1')
$checks = @{}
foreach ($key in $choices.Keys) {
    if ($sections.ContainsKey($key)) {
        $groupCard = [Windows.Controls.Border]::new()
        $groupCard.Style = $Window.Resources['TaskGroup']
        $groupTasks = [Windows.Controls.StackPanel]::new()
        $groupCard.Child = $groupTasks
        $heading = [Windows.Controls.TextBlock]::new()
        $heading.Style = $Window.Resources['Section']
        $heading.Text = $sections[$key][1]
        $heading.Margin = [Windows.Thickness]::new(0)
        $heading.VerticalAlignment = 'Center'
        $badge = [Windows.Controls.Border]::new()
        $badge.Style = $Window.Resources['PhaseBadge']
        $badgeText = [Windows.Controls.TextBlock]::new()
        $badgeText.Style = $Window.Resources['Eyebrow']
        $badgeText.Text = $sections[$key][0]
        $badge.Child = $badgeText
        $groupHeader = [Windows.Controls.DockPanel]::new()
        $groupHeader.Margin = [Windows.Thickness]::new(4, 2, 4, 6)
        [void]$groupHeader.Children.Add($badge)
        [void]$groupHeader.Children.Add($heading)
        [void]$groupTasks.Children.Add($groupHeader)
        [void]$controls.Options.Children.Add($groupCard)
        if ($key -eq 'Disk') { $diskCard = $groupCard }
    }
    $box = [Windows.Controls.CheckBox]::new()
    $label = [Windows.Controls.TextBlock]::new()
    $label.Text = $choices[$key][0]
    $label.TextWrapping = 'Wrap'
    $box.Content = $label
    [Windows.Automation.AutomationProperties]::SetName($box, $label.Text)
    $box.IsChecked = if ($resume) { $key -eq 'Update' } else { $choices[$key][1] }
    $checks[$key] = $box
    [void]$groupTasks.Children.Add($box)
    if ($key -eq 'Apps') {
        $appPicker = [Windows.Controls.Button]::new()
        $appPicker.Content = 'เลือกรายการโปรแกรม…'
        $appPicker.HorizontalAlignment = 'Left'
        $appPicker.Margin = [Windows.Thickness]::new(24, 0, 0, 4)
        $appPicker.Add_Click({ Edit-AppSelection })
        [void]$groupTasks.Children.Add($appPicker)
    }
}

function Update-SelectionSummary {
    $visible = @($checks.Values | Where-Object Visibility -eq 'Visible')
    $count = @($visible | Where-Object IsChecked).Count
    $controls.SelectionCount.Text = "เลือก $count จาก $($visible.Count) งาน"
    $controls.StartButton.IsEnabled = $count -gt 0 -and -not $ui.Handle -and -not $ui.Reboot -and -not $ui.ResumeFinished
}
function Update-PayloadTaskVisibility {
    $payload = Join-Path $Root 'payloads'
    $folders = $PayloadFolders + @{ Disk = 'ใส่ให้ลูกค้า'; Fonts = '++Front' }
    foreach ($key in $folders.Keys) {
        $checks[$key].Visibility = if (Test-Path -LiteralPath (Join-Path $payload $folders[$key]) -PathType Container) {
            'Visible'
        } else { 'Collapsed' }
    }
    $diskCard.Visibility = $checks.Disk.Visibility
    $controls.InstallOffice.Visibility = $checks.Office.Visibility
    $controls.ActivateMas.Visibility = if (Test-Path -LiteralPath (Join-Path $payload 'MASMAX') -PathType Container) {
        'Visible'
    } else { 'Collapsed' }
    $controls.OpenOfficeInstaller.Visibility = if (Test-Path -LiteralPath (Join-Path $payload 'OfficeInstaller++') -PathType Container) {
        'Visible'
    } else { 'Collapsed' }
    $controls.OpenOfficeTool.Visibility = if (Test-Path -LiteralPath $officeToolPath -PathType Leaf) {
        'Visible'
    } else { 'Collapsed' }
    $controls.Extras.Visibility = if (@($controls.ActivateMas, $controls.OpenOfficeInstaller, $controls.OpenOfficeTool) |
        Where-Object Visibility -eq 'Visible') { 'Visible' } else { 'Collapsed' }
    Update-SelectionSummary
}
$ui = @{ Work = $null; Space = $null; Handle = $null; Token = $null; Mode = ''; Resume = $resume }
foreach ($box in $checks.Values) {
    $box.Add_Checked({ Update-SelectionSummary })
    $box.Add_Unchecked({ Update-SelectionSummary })
}
function Edit-AppSelection([switch]$AppsOnly) {
    if ($ui.Handle -or $ui.Reboot -or $ui.Resume) { return }
    try {
        $updated = Show-AppSelection $Window (Join-Path $Root 'payloads\Apps') $configPath $Config
        if (-not $updated) { return }
        $Config.Packages.Apps = $updated.Packages.Apps
        Update-PayloadTaskVisibility
        if ($AppsOnly) {
            foreach ($key in $choices.Keys) { $checks[$key].IsChecked = $false }
        }
        $checks.Apps.IsChecked = [bool]($Config.Packages.Apps | Where-Object { $_.Enabled -ne $false })
        $controls.Status.Text = 'บันทึกรายการโปรแกรมทั่วไปแล้ว'
    } catch {
        [void][Windows.MessageBox]::Show($Window, $_.Exception.Message, 'โปรแกรมทั่วไป', 'OK', 'Error')
    }
}
$controls.AppsOnlyButton.Add_Click({ Edit-AppSelection -AppsOnly })
$controls.ClearButton.Add_Click({
    foreach ($box in $checks.Values) { $box.IsChecked = $false }
})
$controls.QuickActions.IsEnabled = -not $resume
$controls.Options.IsEnabled = -not $resume
Update-PayloadTaskVisibility

$events = [Collections.Concurrent.ConcurrentQueue[object]]::new()
# ส่งสถานะผ่านคิว กิจกรรมที่ใช้เวลานานอยู่ใน Runspace นี้ทั้งหมด
$worker = {
    param($Root, $Config, $PayloadFolders, $StatePath, $ResumeTask, $Events, $Cancel, $Selected, $LogPath, $WorkerMode, $DataPercent)
    $ErrorActionPreference = 'Stop'
    function Publish($Kind, $Value) { $Events.Enqueue(@{ Kind = $Kind; Value = $Value }) }
    function Write-Log([string]$Message) {
        $line = ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f [DateTime]::Now,$Message)
        [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
        Publish Log $line
    }
    function Assert-Running {
        if ($Cancel.IsCancellationRequested) { throw [OperationCanceledException]::new('ยกเลิกตามคำสั่งผู้ใช้') }
    }
    function Invoke-Program([string]$File, [string]$Arguments, [int]$Timeout, [int[]]$SuccessCodes, [string]$WorkingDirectory = $Root, [switch]$IgnoreCancellation, [switch]$CaptureOutput, [switch]$SuppressOutput, [switch]$PassExitCode) {
        if (-not $IgnoreCancellation) { Assert-Running }
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $File
        $info.Arguments = $Arguments
        $info.WorkingDirectory = $WorkingDirectory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        try {
            [void]$process.Start()
            if ($SuppressOutput) {
                $stdout = $process.StandardOutput.BaseStream.CopyToAsync([IO.Stream]::Null)
                $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
            } else {
                $stdout = $process.StandardOutput.ReadToEndAsync()
                $stderr = $process.StandardError.ReadToEndAsync()
            }
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while (-not $process.WaitForExit(250)) {
                if ($timer.Elapsed.TotalSeconds -ge $Timeout) {
                    $kill = Start-Process "$env:SystemRoot\System32\taskkill.exe" -ArgumentList "/PID $($process.Id) /T /F" -WindowStyle Hidden -PassThru
                    try {
                        if (-not $kill.WaitForExit(5000) -or -not $process.WaitForExit(5000)) {
                            throw "หมดเวลารอ $File และยังยืนยันการหยุดตัวติดตั้งไม่ได้"
                        }
                    } finally { $kill.Dispose() }
                    throw "หมดเวลารอ $File ($Timeout วินาที)"
                }
            }
            if (-not $CaptureOutput -and -not $SuppressOutput) {
                foreach ($stream in $stdout,$stderr) {
                    if ($stream.Wait(1000) -and $stream.Result.Trim()) { Write-Log $stream.Result.TrimEnd() }
                }
            }
            $code = $process.ExitCode
            if (-not $SuppressOutput) { Write-Log "$([IO.Path]::GetFileName($File)) Exit Code $code" }
            if ($code -notin $SuccessCodes) { throw "$File ทำงานไม่สำเร็จ (Exit Code $code)" }
            if (-not $SuppressOutput -and $code -in 3010,1641) { Write-Log 'ตัวติดตั้งแจ้งว่าต้องรีสตาร์ท' }
            if (-not $IgnoreCancellation) { Assert-Running }
            if ($PassExitCode) { return $code }
            if ($CaptureOutput -and -not $SuppressOutput -and $stdout.Wait(1000)) { return $stdout.Result }
        } finally { $process.Dispose() }
    }
    function Update-OfficeLicense {
        try {
            . (Join-Path $Root 'modules\07-OfficeLicense.ps1')
            Publish OfficeLicense (Get-OfficeLicenseSummary)
        } catch {
            Publish OfficeLicense @{ Text = 'ตรวจสถานะการติดตั้ง Office ไม่สำเร็จ กดตรวจสถานะเพื่อลองใหม่' }
        }
    }
    if ($WorkerMode -in 'Inventory','LicenseScan') {
        try {
            . (Join-Path $Root 'modules\06-WindowsLicense.ps1')
            Publish WindowsLicense (Get-WindowsLicenseSummary)
        } catch {
            Publish WindowsLicense 'ตรวจสถานะสิทธิ์ Windows ไม่สำเร็จ กดตรวจใหม่เพื่อลองอีกครั้ง'
        }
        Update-OfficeLicense
        if ($WorkerMode -eq 'LicenseScan') { return }
    }
    if ($WorkerMode -eq 'PayloadCheck') {
        . (Join-Path $Root 'modules\03-InstallAllAndFix.ps1')
        Publish PayloadReport ((Get-PayloadReport) -join [Environment]::NewLine)
        return
    }
    if ($WorkerMode -eq 'Inventory') {
        . (Join-Path $Root 'modules\05-HardwareAndDrivers.ps1')
        try { Publish Specs (Get-MachineSpecs) } catch { Publish SpecsError $_.Exception.Message }
        . (Join-Path $Root 'modules\03-InstallAllAndFix.ps1')
        Publish Inventory @(Get-PackageInventory)
        return
    }
    if ($WorkerMode -eq 'DriverScan') {
        . (Join-Path $Root 'modules\05-HardwareAndDrivers.ps1')
        try {
            Invoke-DriverCheck
            Publish DriverStatus 'ตรวจเสร็จแล้ว ยังไม่ได้ติดตั้งไดรเวอร์'
        } catch [OperationCanceledException] {
            Publish DriverStatus 'ยกเลิกการตรวจไดรเวอร์แล้ว'
        } catch {
            Write-Log $_.Exception.Message
            Publish DriverUpdates @('ไม่สามารถอ่านรายการจาก Windows Update ได้')
            Publish DriverStatus 'ตรวจไดรเวอร์ไม่สำเร็จ ดูรายละเอียดใน Log'
        }
        return
    }
    try {
        foreach ($module in '01-DiskAndData','02-SystemTweaks','03-InstallAllAndFix','04-WindowsUpdateLoop','05-HardwareAndDrivers') {
            . (Join-Path $Root "modules\$module.ps1")
        }
        $completed = 0
        $printerIncomplete = $false
        $unavailableCount = 0
        $autoRestart = $WorkerMode -in 'Autorun','UpdateResumeAuto'
        foreach ($key in $Selected) {
            Assert-Running
            Publish Step $key
            if ($key -ne 'ACDSee') { Write-Log "เริ่ม $key" }
            switch ($key) {
                SMB { Enable-SmbFileSharing }
                Disk { Invoke-DiskAndData -DataPercent $DataPercent }
                System { Invoke-SystemTweaks }
                GraveAccent { Enable-GraveAccentLanguageSwitch }
                Printer { $printerIncomplete = -not (Invoke-PrinterFix) }
                Fonts { Install-LocalFonts }
                Drivers { Invoke-DriverCheck -Install }
                Update { Invoke-WindowsUpdateLoop -AutoRestart:$autoRestart }
                default {
                    Invoke-PayloadGroup $key -SkipUnavailable:($WorkerMode -eq 'Autorun') `
                        -SkipMissing -UnavailableCount ([ref]$unavailableCount)
                }
            }
            if ($script:UpdateRestartPending) { break }
            $completed++
            Publish Progress (100.0 * $completed / $Selected.Count)
            if ($script:DriverRestartRequired) { break }
        }
        $message = if ($script:DriverRestartRequired) { 'ต้องรีสตาร์ทเครื่องก่อนทำงานที่เหลือ' }
            elseif ($script:UpdateRestartPending -and $autoRestart) { 'กำลังรีสตาร์ทเครื่องเพื่อทำ Windows Update ต่อ' }
            elseif ($script:UpdateRestartPending) { 'กดรีสตาร์ทเครื่องและยืนยัน เพื่อทำ Windows Update ต่อ' }
            elseif ($printerIncomplete -and $unavailableCount -gt 0) { "จบงานแล้ว: Printer ไม่สำเร็จและข้าม $unavailableCount รายการ ดูรายละเอียดใน Log" }
            elseif ($printerIncomplete) { 'จบงานแล้ว แต่ขั้นตอน Printer ไม่สำเร็จทั้งหมด ดูรายละเอียดใน Log' }
            elseif ($unavailableCount -gt 0) {
                $finished = if ($WorkerMode -eq 'Autorun') { 'จบ Autorun แล้ว' } else { 'จบงานแล้ว' }
                "${finished}: ข้าม $unavailableCount รายการเพราะไฟล์ติดตั้งไม่พร้อม ดูรายละเอียดใน Log"
            }
            else { 'เสร็จสิ้น' }
        if ($Selected.Count -ne 1 -or $Selected[0] -ne 'ACDSee') { Write-Log $message }
        Publish Status $message
        if (-not $script:UpdateRestartPending -and ($Selected | Where-Object { $_ -in 'Apps','Runtimes','Foxit','ACDSee','LINE','Office' })) {
            try { Publish Inventory @(Get-PackageInventory) } catch { Write-Log "ตรวจรายการโปรแกรมซ้ำไม่สำเร็จ: $_" }
        }
        if (-not $script:UpdateRestartPending -and $Selected -contains 'Office') { Update-OfficeLicense }
        if ($script:UpdateRestartPending) { Publish Reboot $autoRestart }
        elseif ($Selected -contains 'Update') { Publish ResumeCleared $true }
    } catch [OperationCanceledException] {
        if ($key -eq 'Drivers') { Publish DriverStatus 'ยกเลิกงานไดรเวอร์แล้ว' }
        if ($key -eq 'Update' -and -not $script:UpdateRestartPending -and (Test-Path -LiteralPath $StatePath) -and
            (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json).Mode -eq 'UpdateLoop') {
            Clear-UpdateResume
            Publish ResumeCleared $true
        }
        Write-Log $_.Exception.Message
        Publish Status 'ยกเลิกแล้ว'
    } catch {
        if ($key -eq 'Drivers' -and -not $script:DriverRestartRequired) {
            Publish DriverStatus 'งานไดรเวอร์ไม่สำเร็จทั้งหมด ดูรายละเอียดใน Log'
        }
        Write-Log ("ผิดพลาด: {0}" -f $_.Exception.Message)
        Publish Status 'หยุดเนื่องจากข้อผิดพลาด ดูรายละเอียดใน Log'
    }
}

function Start-Work([string]$Mode, [string[]]$Selected, [int]$DataPercent = 0) {
    $log = Join-Path $logDir ((Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff') + "_$Mode.log")
    $ui.Mode = $Mode
    $ui.Token = [Threading.CancellationTokenSource]::new()
    $ui.Space = [RunspaceFactory]::CreateRunspace()
    $ui.Space.ApartmentState = 'STA'
    $ui.Space.ThreadOptions = 'ReuseThread'
    $ui.Space.Open()
    $ui.Work = [PowerShell]::Create()
    $ui.Work.Runspace = $ui.Space
    [void]$ui.Work.AddScript($worker.ToString())
    [void]$ui.Work.AddArgument($Root).AddArgument($Config).AddArgument($PayloadFolders).AddArgument($StatePath).
        AddArgument($ResumeTask).AddArgument($events).AddArgument($ui.Token.Token).AddArgument($Selected).
        AddArgument($log).AddArgument($Mode).AddArgument($DataPercent)
    $ui.Handle = $ui.Work.BeginInvoke()
    $poll.Start()
}
function Set-Busy([bool]$Busy) {
    if (-not $Busy -and $null -ne $ui.BeforeAutorunSelection) {
        foreach ($key in $choices.Keys) { $checks[$key].IsChecked = $key -in $ui.BeforeAutorunSelection }
        $ui.BeforeAutorunSelection = $null
    }
    if ($Busy) { $controls.StartButton.IsEnabled = $false } else { Update-SelectionSummary }
    $controls.RestartButton.IsEnabled = -not $Busy
    $controls.CancelButton.IsEnabled = $Busy
    $controls.RefreshInventory.IsEnabled = -not $Busy -and -not $ui.Reboot
    $controls.RefreshLicense.IsEnabled = -not $Busy -and -not $ui.Reboot
    $canChangeLicense = -not $Busy -and -not $ui.Reboot -and -not $ui.Resume
    $controls.InstallOffice.IsEnabled = $canChangeLicense -and $ui.OfficeLicense.CanInstall -and
        [bool]($Config.Packages.Office | Where-Object { $_.Enabled -ne $false })
    $controls.ActivationSettings.IsEnabled = $canChangeLicense
    $controls.ActivateMas.IsEnabled = $canChangeLicense
    $controls.OpenOfficeTool.IsEnabled = $canChangeLicense
    $controls.ScanDrivers.IsEnabled = -not $Busy -and -not $ui.Reboot -and -not $ui.Resume
    $controls.Options.IsEnabled = -not $Busy -and -not $ui.Resume
    $controls.QuickActions.IsEnabled = $controls.Options.IsEnabled
}
function Set-WaitStatus([string]$Message) {
    if ($null -eq $ui.StatusBeforeWait) { $ui.StatusBeforeWait = $controls.Status.Text }
    $controls.Status.Text = $Message
}
$poll = [Windows.Threading.DispatcherTimer]::new()
$poll.Interval = [TimeSpan]::FromMilliseconds(150)
$poll.Add_Tick({
    # อัปเดตหน้าต่างผ่าน Dispatcher หลังรับข้อมูลจาก Runspace
    $Window.Dispatcher.Invoke([Action]{
        $eventItem = $null
        while ($events.TryDequeue([ref]$eventItem)) {
            switch ($eventItem.Kind) {
                Log {
                    $followLog = ($controls.LogBox.ExtentHeight - $controls.LogBox.ViewportHeight - $controls.LogBox.VerticalOffset) -le 1
                    $controls.LogBox.AppendText([string]$eventItem.Value + [Environment]::NewLine)
                    if ($controls.LogBox.Text.Length -gt 200000) {
                        $controls.LogBox.Text = $controls.LogBox.Text.Substring($controls.LogBox.Text.Length - 150000)
                    }
                    if ($followLog) { $controls.LogBox.ScrollToEnd() }
                }
                Step {
                    if (-not $ui.Token.IsCancellationRequested) {
                        $ui.StatusBeforeWait = $null
                        $controls.Status.Text = $choices[$eventItem.Value][0]
                    }
                    if ($eventItem.Value -eq 'Drivers') {
                        $controls.DriverSummary.Text = 'กำลังตรวจและติดตั้งไดรเวอร์…'
                        $controls.MissingDrivers.Text = $controls.AvailableDrivers.Text = 'กำลังตรวจ…'
                    }
                    $controls.Progress.IsIndeterminate = $eventItem.Value -in 'Update','Drivers'
                    if ($controls.Progress.IsIndeterminate) { $controls.ProgressLabel.Text = 'กำลังประมวลผล' }
                }
                Progress {
                    $controls.Progress.IsIndeterminate = $false
                    $controls.Progress.Value = [double]$eventItem.Value
                    $controls.ProgressLabel.Text = '{0:0}%' -f $controls.Progress.Value
                }
                Status {
                    $ui.StatusBeforeWait = $null
                    $controls.Status.Text = $eventItem.Value
                }
                Inventory {
                    $rows = @($eventItem.Value)
                    $controls.PayloadReportPane.Visibility = 'Collapsed'
                    $controls.InventoryList.Visibility = 'Visible'
                    $controls.InventoryList.ItemsSource = $rows
                    $installedCount = @($rows | Where-Object Status -eq 'ติดตั้งแล้ว').Count
                    $controls.InventorySummary.Text = "พบว่าติดตั้งแล้ว $installedCount จาก $($rows.Count) รายการ"
                }
                PayloadReport {
                    Update-PayloadTaskVisibility
                    $controls.PayloadReport.Text = $eventItem.Value
                    $controls.InventorySummary.Text = 'ผลตรวจไฟล์ Payload'
                }
                Specs {
                    $controls.SpecsDetails.DataContext = $eventItem.Value
                    $controls.SpecsDetails.Visibility = 'Visible'
                    $controls.SpecsText.Visibility = 'Collapsed'
                }
                SpecsError {
                    $controls.SpecsDetails.Visibility = 'Collapsed'
                    $controls.SpecsText.Text = "อ่านสเปกไม่สำเร็จ: $($eventItem.Value)"
                    $controls.SpecsText.Visibility = 'Visible'
                }
                WindowsLicense { $controls.LicenseSummary.Text = $eventItem.Value }
                OfficeLicense {
                    $ui.OfficeLicense = $eventItem.Value
                    $controls.OfficeLicenseSummary.Text = $eventItem.Value.Text
                }
                DriverStatus {
                    $controls.DriverSummary.Text = $eventItem.Value
                    if ($ui.Mode -eq 'DriverScan' -and $ui.Token.IsCancellationRequested) {
                        $ui.StatusBeforeWait = $null
                        $controls.Status.Text = $eventItem.Value
                    }
                    foreach ($name in 'MissingDrivers','AvailableDrivers') {
                        if ($controls[$name].Text -eq 'กำลังตรวจ…') { $controls[$name].Text = 'ไม่มีผลตรวจ' }
                    }
                }
                DriverDevices {
                    $controls.MissingDrivers.Text = if ($eventItem.Value) { $eventItem.Value -join "`n" } else { 'ไม่พบอุปกรณ์ที่ Windows แจ้งว่าขาดไดรเวอร์' }
                }
                DriverUpdates {
                    $controls.AvailableDrivers.Text = if ($eventItem.Value) { $eventItem.Value -join "`n" } else { 'ไม่พบไดรเวอร์ที่เสนอสำหรับเครื่องนี้' }
                }
                Reboot {
                    $ui.Reboot = $true
                    $ui.AutoRestart = $eventItem.Value
                }
                ResumeCleared { if ($ui.Resume) { $ui.ResumeFinished = $true } }
            }
        }
        if ($ui.Handle -and $ui.Handle.IsCompleted -and $events.IsEmpty) {
            $poll.Stop()
            try { [void]$ui.Work.EndInvoke($ui.Handle) }
            catch {
                if ($ui.Mode -eq 'Inventory') { $controls.InventorySummary.Text = 'ตรวจรายการโปรแกรมไม่สำเร็จ กดตรวจใหม่เพื่อลองอีกครั้ง'; $controls.InventorySummary.ToolTip = $_.Exception.Message }
                if ($ui.Mode -eq 'PayloadCheck') { $controls.InventorySummary.Text = 'ตรวจ Payload ไม่สำเร็จ'; $controls.PayloadReport.Text = $_.Exception.Message }
                elseif ($ui.Mode -eq 'LicenseScan') {
                    $controls.LicenseSummary.Text = 'ตรวจสถานะสิทธิ์ Windows ไม่สำเร็จ กดตรวจใหม่เพื่อลองอีกครั้ง'
                    $ui.OfficeLicense = $null
                    $controls.OfficeLicenseSummary.Text = 'ตรวจสถานะ Office ไม่สำเร็จ กดตรวจใหม่เพื่อลองอีกครั้ง'
                }
                else {
                    $ui.StatusBeforeWait = $null
                    $controls.Status.Text = 'เกิดข้อผิดพลาดในงานเบื้องหลัง'
                    $controls.LogBox.AppendText($_.Exception.Message + [Environment]::NewLine)
                }
            } finally {
                if ($null -ne $ui.StatusBeforeWait) {
                    $controls.Status.Text = $ui.StatusBeforeWait
                    $ui.StatusBeforeWait = $null
                }
                $ui.Work.Dispose()
                $ui.Space.Dispose()
                $ui.Token.Dispose()
                $ui.Handle = $null
            }
            $controls.Progress.IsIndeterminate = $false
            $controls.ProgressLabel.Text = '{0:0}%' -f $controls.Progress.Value
            Set-Busy $false
            if ($ui.Reboot -or $ui.ResumeFinished) {
                $controls.StartButton.IsEnabled = $false
                $controls.Options.IsEnabled = $false
                $controls.QuickActions.IsEnabled = $false
            }
            if ($ui.AutoRestart) {
                $ui.AutoRestart = $false
                Request-WindowsRestart
            }
        }
    })
})

function Start-InventoryScan {
    if ($ui.Handle -or $ui.Reboot) { return }
    if ($controls.SpecsText.Visibility -eq 'Visible') { $controls.SpecsText.Text = 'กำลังอ่านสเปก…' }
    $controls.InventorySummary.Text = 'กำลังตรวจโปรแกรม…'
    $controls.LicenseSummary.Text = 'กำลังตรวจสถานะสิทธิ์ Windows…'
    $controls.OfficeLicenseSummary.Text = 'กำลังตรวจสถานะ Office…'
    $controls.InventorySummary.ToolTip = $null
    Set-Busy $true
    $controls.CancelButton.IsEnabled = $false
    Start-Work 'Inventory' @()
}
$controls.RefreshInventory.Add_Click({ Start-InventoryScan })
$controls.CheckPayload.Add_Click({
    if ($ui.Handle -or $ui.Reboot -or $ui.Resume) { return }
    Show-DetailsDrawer $controls.ProgramsNav
    $controls.InventoryList.Visibility = 'Collapsed'
    $controls.PayloadReportPane.Visibility = 'Visible'
    $controls.PayloadReport.Text = ''
    $controls.InventorySummary.Text = 'กำลังตรวจไฟล์ Payload…'
    $controls.InventorySummary.ToolTip = $null
    Set-Busy $true
    $controls.CancelButton.IsEnabled = $false
    Start-Work 'PayloadCheck' @()
})
$controls.RefreshLicense.Add_Click({
    if ($ui.Handle -or $ui.Reboot) { return }
    $controls.LicenseSummary.Text = 'กำลังตรวจสถานะสิทธิ์ Windows…'
    $controls.OfficeLicenseSummary.Text = 'กำลังตรวจสถานะ Office…'
    Set-Busy $true
    $controls.CancelButton.IsEnabled = $false
    Start-Work 'LicenseScan' @()
})
$controls.ActivationSettings.Add_Click({
    try { Start-Process 'ms-settings:activation' -ErrorAction Stop }
    catch { [void][Windows.MessageBox]::Show($Window, 'เปิดหน้า Activation ไม่ได้ ให้ลองเปิดจาก Settings ของ Windows', 'Windows Activation') }
})
$controls.ActivateMas.Add_Click({
    if ($ui.Handle -or $ui.Reboot -or $ui.Resume) { return }
    $masFolder = Join-Path $Root 'payloads\MASMAX'
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $masFolder 'MAS_AIO.cmd') -PathType Leaf)) {
            throw 'ไม่พบไฟล์ payloads\MASMAX\MAS_AIO.cmd'
        }
        Start-Process "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d /c .\MAS_AIO.cmd' -WorkingDirectory $masFolder -ErrorAction Stop
    } catch {
        [void][Windows.MessageBox]::Show($Window, "เปิด MASMAX ไม่ได้: $($_.Exception.Message)", 'MASMAX')
    }
})
$controls.OpenOfficeInstaller.Add_Click({
    $installerFolder = Join-Path $Root 'payloads\OfficeInstaller++'
    $installerName = if ([Environment]::Is64BitOperatingSystem) {
        'Office Installer+ x64.exe'
    } else {
        'Office Installer+.exe'
    }
    try {
        Start-Process -FilePath (Join-Path $installerFolder $installerName) -WorkingDirectory $installerFolder -ErrorAction Stop
    } catch {
        [void][Windows.MessageBox]::Show($Window, "เปิด OfficeInstall++ ไม่ได้: $($_.Exception.Message)", 'OfficeInstall++')
    }
})
$controls.OpenOfficeTool.Add_Click({
    if ($ui.Handle -or $ui.Reboot -or $ui.Resume) { return }
    try {
        Start-Process -FilePath $officeToolPath -WorkingDirectory (Split-Path -LiteralPath $officeToolPath) -ErrorAction Stop
    } catch {
        [void][Windows.MessageBox]::Show($Window, "เปิด Office Tool Plus ไม่ได้: $($_.Exception.Message)", 'Office Tool Plus')
    }
})
$controls.ScanDrivers.Add_Click({
    if ($ui.Handle -or $ui.Reboot -or $ui.Resume) { return }
    $controls.DriverSummary.Text = 'กำลังตรวจอุปกรณ์และค้นหา Windows Update…'
    $controls.MissingDrivers.Text = $controls.AvailableDrivers.Text = 'กำลังตรวจ…'
    Set-Busy $true
    Start-Work 'DriverScan' @()
})

function Show-PartitionDialog {
    [xml]$partitionXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="สัดส่วนพาร์ติชัน" Width="540" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI" FontSize="14"
        Background="{DynamicResource CanvasBrush}" Foreground="{DynamicResource TextBrush}">
  <StackPanel Margin="24">
    <TextBlock Text="พื้นที่จัดเก็บ" Style="{DynamicResource Eyebrow}"/>
    <TextBlock Text="แบ่งพื้นที่ Windows และ Data" FontSize="24" FontWeight="SemiBold" Margin="0,4,0,0"/>
    <TextBlock Text="เลือกเปอร์เซ็นต์ Data จากช่วงพื้นที่ต่อเนื่องที่แบ่งได้บนดิสก์ Windows" Margin="0,8,0,16" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
    <Border Style="{DynamicResource Card}" Background="{DynamicResource SoftBrush}">
      <StackPanel>
        <TextBlock Name="Ratio" Text="Windows 50%  /  Data 50%" Foreground="{DynamicResource AccentBrush}" FontSize="20" FontWeight="SemiBold"/>
        <Slider Name="DataPercent" Minimum="1" Maximum="99" Value="50" IsSnapToTickEnabled="True" TickFrequency="1"
                LargeChange="10" Margin="0,12,0,0" AutomationProperties.Name="เปอร์เซ็นต์ Data"/>
      </StackPanel>
    </Border>
    <TextBlock Text="สำรองข้อมูลก่อนดำเนินการ แอปจะตรวจสัดส่วนที่ Windows อนุญาตก่อนย่อ หากมี Volume Data อยู่แล้วบนดิสก์ Windows จะใช้ Volume เดิมโดยไม่แบ่งใหม่" Margin="0,12,0,18" TextWrapping="Wrap" Foreground="{DynamicResource MutedBrush}"/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
      <Button Content="ยกเลิก" Style="{DynamicResource QuietButton}" IsCancel="True" Margin="0,0,8,0"/>
      <Button Name="ConfirmSplit" Content="ยืนยันสัดส่วน" Style="{DynamicResource PrimaryButton}"/>
    </StackPanel>
  </StackPanel>
</Window>
"@
    $dialog = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($partitionXaml))
    $dialog.Icon = $Window.Icon
    $dialog.Resources.MergedDictionaries.Add($Window.Resources)
    $dialog.Owner = $Window
    $slider = $dialog.FindName('DataPercent')
    $ratio = $dialog.FindName('Ratio')
    $slider.Add_ValueChanged({
        param($sender, $eventArgs)
        $ratio.Text = 'Windows {0}%  /  Data {1}%' -f (100 - $eventArgs.NewValue), $eventArgs.NewValue
    }.GetNewClosure())
    $dialog.FindName('ConfirmSplit').Add_Click({ $dialog.DialogResult = $true }.GetNewClosure())
    if ($dialog.ShowDialog() -eq $true) { return [int]$slider.Value }
}

function Start-SelectedSetup([switch]$OfficeOnly, [switch]$StartupInstall) {
    if ($ui.Handle -or $ui.Reboot -or $ui.ResumeFinished) { return }
    Update-PayloadTaskVisibility
    $selected = @(if ($ui.Resume) { 'Update' }
        elseif ($StartupInstall) { 'Printer','Runtimes','Apps','LINE','Office','Update' }
        elseif ($OfficeOnly) { 'Office' } else { $choices.Keys | Where-Object { $checks[$_].IsChecked } })
    $selected = @($selected | Where-Object { $checks[$_].Visibility -eq 'Visible' })
    if (-not $selected) { $controls.Status.Text = 'เลือกอย่างน้อยหนึ่งรายการ'; return }
    $dataPercent = 0
    if ($selected -contains 'Disk') {
        $dataPercent = Show-PartitionDialog
        if ($null -eq $dataPercent) { return }
    }
    if ($StartupInstall) {
        $ui.BeforeAutorunSelection = @($choices.Keys | Where-Object { $checks[$_].IsChecked })
        foreach ($key in $choices.Keys) { $checks[$key].IsChecked = $key -in $selected }
    }
    if (-not $OfficeOnly) { Show-DetailsDrawer $controls.LogNav }
    $controls.Progress.Value = 0
    $controls.ProgressLabel.Text = '0%'
    $controls.Status.Text = 'กำลังเริ่มงาน'
    Set-Busy $true
    $mode = if ($ui.Resume -and $resumeAutoRestart) { 'UpdateResumeAuto' }
        elseif ($StartupInstall) { 'Autorun' }
        else { 'Setup' }
    Start-Work $mode $selected $dataPercent
}
$controls.StartButton.Add_Click({ Start-SelectedSetup })
$controls.InstallOffice.Add_Click({
    if ($ui.Handle -or $ui.Reboot -or $ui.Resume -or -not $ui.OfficeLicense.CanInstall) { return }
    if ([Windows.MessageBox]::Show($Window, 'ดาวน์โหลดและติดตั้ง Office Professional Plus 2024 Retail จาก Microsoft ตอนนี้หรือไม่?', 'ยืนยันการติดตั้ง Office', 'YesNo', 'Question') -eq 'Yes') {
        Start-SelectedSetup -OfficeOnly
    }
})
$controls.CancelButton.Add_Click({
    $ui.Token.Cancel()
    $controls.CancelButton.IsEnabled = $false
    Set-WaitStatus 'กำลังรอให้ขั้นตอนปัจจุบันสิ้นสุดก่อนยกเลิก'
})
$controls.LogsButton.Add_Click({ Start-Process explorer.exe -ArgumentList ('"{0}"' -f $logDir) })
function Request-WindowsRestart {
    try {
        $restart = Start-Process "$env:SystemRoot\System32\shutdown.exe" -ArgumentList '/r /t 0' -WindowStyle Hidden -Wait -PassThru
        if ($restart.ExitCode -ne 0) { throw "Exit Code $($restart.ExitCode)" }
    } catch {
        $controls.Status.Text = "รีสตาร์ทไม่สำเร็จ ($($_.Exception.Message)) กดรีสตาร์ทเครื่องเพื่อลองอีกครั้ง"
    }
}
$controls.RestartButton.Add_Click({
    if ([Windows.MessageBox]::Show($Window, 'รีสตาร์ท Windows ตอนนี้หรือไม่?', 'Restart Now', 'YesNo', 'Question') -ne 'Yes') { return }
    Request-WindowsRestart
})
$Window.Add_Closing({
    param($sender, $e)
    if ($ui.Handle) {
        $e.Cancel = $true
        $waitMessage = if ($controls.CancelButton.IsEnabled) {
            'กด ยกเลิกงาน และรอให้งานปัจจุบันสิ้นสุดก่อนปิดหน้าต่าง'
        } else { 'รอให้งานปัจจุบันสิ้นสุดก่อนปิดหน้าต่าง' }
        Set-WaitStatus $waitMessage
    }
})

if ($resume) {
    $Window.Add_ContentRendered({ Start-SelectedSetup })
} elseif ($StartupLaunch -and $AutoInstall) {
    $Window.Add_ContentRendered({ Start-SelectedSetup -StartupInstall })
} else {
    $Window.Add_ContentRendered({ Start-InventoryScan })
}
$antivirusScan = @{ Work = $null; Handle = $null }
$antivirusPoll = [Windows.Threading.DispatcherTimer]::new()
$antivirusPoll.Interval = [TimeSpan]::FromMilliseconds(150)
$antivirusRefresh = [Windows.Threading.DispatcherTimer]::new()
$antivirusRefresh.Interval = [TimeSpan]::FromSeconds(30)

function Update-AntivirusAlert($Results) {
    $message = if ($Results | Where-Object RealtimeEnabled) {
        'Microsoft Defender เปิดการป้องกันแบบเรียลไทม์อยู่'
    } elseif ($Results | Where-Object SecurityCenterActive) {
        'Windows Security รายงานว่าแอนติไวรัสเปิดการป้องกันอยู่'
    }
    $controls.AntivirusAlertText.Text = [string]$message
    $controls.AntivirusAlert.Visibility = if ($message) { 'Visible' } else { 'Collapsed' }
}

function Start-AntivirusScan {
    if ($antivirusScan.Work) { return }
    $controls.RefreshAntivirus.IsEnabled = $false
    $controls.AntivirusSummary.Text = 'กำลังตรวจสถานะ…'
    $antivirusScan.Work = [PowerShell]::Create()
    try {
        [void]$antivirusScan.Work.AddCommand((Join-Path $Root 'modules\00-PreFlight-AV.ps1'))
        $antivirusScan.Handle = $antivirusScan.Work.BeginInvoke()
        $antivirusPoll.Start()
    } catch {
        $antivirusScan.Work.Dispose()
        $antivirusScan.Work = $null
        $controls.AntivirusSummary.Text = 'ตรวจสถานะไม่สำเร็จ'
        $controls.RefreshAntivirus.IsEnabled = $true
    }
}

$antivirusPoll.Add_Tick({
    if (-not $antivirusScan.Handle.IsCompleted) { return }
    $antivirusPoll.Stop()
    try {
        $result = @($antivirusScan.Work.EndInvoke($antivirusScan.Handle))
        if ($antivirusScan.Work.HadErrors -or $result.Count -eq 0) { throw 'Antivirus status unavailable' }
        $controls.AntivirusDetails.Text = ($result | ForEach-Object Detail) -join [Environment]::NewLine
        Update-AntivirusAlert $result
        $controls.AntivirusSummary.Text = 'ตรวจล่าสุด {0:HH:mm:ss}' -f (Get-Date)
    } catch {
        $controls.AntivirusSummary.Text = 'ตรวจสถานะไม่สำเร็จ'
    } finally {
        $antivirusScan.Work.Dispose()
        $antivirusScan.Work = $null
        $antivirusScan.Handle = $null
        $controls.RefreshAntivirus.IsEnabled = $true
    }
})
$controls.RefreshAntivirus.Add_Click({ Start-AntivirusScan })
$antivirusRefresh.Add_Tick({ Start-AntivirusScan })
$Window.Add_Loaded({
    Start-AntivirusScan
    $antivirusRefresh.Start()
})
$controls.OpenWindowsSecurity.Add_Click({
    try {
        Start-Process 'windowsdefender:' -ErrorAction Stop
    } catch {
        [void][Windows.MessageBox]::Show($Window, 'เปิด Windows Security ไม่สำเร็จ', 'Windows Security', 'OK', 'Error')
    }
})
$Window.Add_Closed({
    $antivirusRefresh.Stop()
    $antivirusPoll.Stop()
})
[void]$Window.ShowDialog()
} catch {
    [void][Windows.MessageBox]::Show($_.Exception.Message, 'Windows Auto Setup', 'OK', 'Error')
    exit 1
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    if ($antivirusScan -and $antivirusScan.Work) { $antivirusScan.Work.Dispose() }
}
