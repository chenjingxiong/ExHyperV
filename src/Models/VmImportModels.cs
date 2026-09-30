using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Globalization;
using CommunityToolkit.Mvvm.ComponentModel;
using ExHyperV.Properties;
using ExHyperV.Tools;

namespace ExHyperV.Models;

public enum VmImportSourceKind
{
    Folder,
    Zip
}

/// <summary>导入时网卡 MAC 地址的处理方式。</summary>
public enum VmImportMacMode
{
    /// <summary>保留导出配置中的 MAC（静态保持静态，动态保持动态）。</summary>
    KeepOriginal,
    /// <summary>改为动态 MAC，由 Hyper-V 在启动时按新虚拟机标识自动分配。</summary>
    Dynamic,
    /// <summary>由用户指定的静态 MAC。</summary>
    Custom
}

public enum VmImportPlacementMode
{
    HostDirectories,
    ExistingDirectory
}

public sealed class VmImportDiskPreview
{
    public string Name { get; init; } = string.Empty;
    public string SourcePath { get; init; } = string.Empty;
    public string Controller { get; init; } = string.Empty;
    public string Format { get; init; } = string.Empty;
    public string Type { get; init; } = string.Empty;
    public ulong VirtualSize { get; init; }
    public long ActualSize { get; init; }
    public string? ParentPath { get; init; }
    public bool Exists { get; init; }

    public string SlotText => string.IsNullOrWhiteSpace(Controller) ? "—" : Controller;
    public string KindText => string.Join(" · ", new[] { Format, Type }.Where(x => !string.IsNullOrWhiteSpace(x)));
    public string VirtualSizeText => FormatBytes(VirtualSize);
    public string ActualSizeText => FormatBytes((ulong)Math.Max(0, ActualSize));

    private static string FormatBytes(ulong bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB"];
        double value = bytes;
        int unit = 0;
        while (value >= 1024 && unit < units.Length - 1)
        {
            value /= 1024;
            unit++;
        }

        return unit == 0 ? $"{value:0} {units[unit]}" : $"{value:0.##} {units[unit]}";
    }
}

/// <summary>导入预览里的单块网卡；MAC 处理方式可由用户编辑。</summary>
public sealed class VmImportNetworkPreview : ObservableObject
{
    private VmImportMacMode _mode = VmImportMacMode.KeepOriginal;
    private string _customMac = string.Empty;
    private string? _hint;

    public string Name { get; init; } = string.Empty;
    /// <summary>VMCX 设备节点 GUID（小写），与 WMI 网卡 InstanceID 的第二段对应，
    /// 用于在计划虚拟机上定位同一块网卡。实测 GenerateNewSystemIdentifier 不改设备 GUID。</summary>
    public string DeviceId { get; init; } = string.Empty;
    public string OriginalSwitchName { get; init; } = string.Empty;
    public bool IsConnected { get; init; }
    /// <summary>来源配置中的 MAC（12 位无分隔大写）；动态网卡也会带最近一次分配值。</summary>
    public string OriginalMac { get; init; } = string.Empty;
    public bool OriginalMacIsStatic { get; init; }

    public VmImportMacMode Mode
    {
        get => _mode;
        set
        {
            if (SetProperty(ref _mode, value))
                OnPropertyChanged(nameof(IsCustomMode));
        }
    }

    public bool IsCustomMode => Mode == VmImportMacMode.Custom;

    public string CustomMac
    {
        get => _customMac;
        set => SetProperty(ref _customMac, value ?? string.Empty);
    }

    /// <summary>非阻断提示（如“原 MAC 与现有虚拟机冲突，已改用动态 MAC”）。</summary>
    public string? Hint
    {
        get => _hint;
        set
        {
            if (SetProperty(ref _hint, value))
                OnPropertyChanged(nameof(HasHint));
        }
    }
    public bool HasHint => !string.IsNullOrWhiteSpace(Hint);

    /// <summary>当前选择对应的静态 MAC；null = 动态。自定义输入非法时也返回 null，由 <see cref="IsCustomMacMissingOrInvalid"/> 标记问题。</summary>
    public string? EffectiveStaticMac => Mode switch
    {
        VmImportMacMode.Dynamic => null,
        VmImportMacMode.KeepOriginal => OriginalMacIsStatic ? OriginalMac : null,
        VmImportMacMode.Custom => MacAddress.Normalize(CustomMac) is { Length: 12 } mac ? mac : null,
        _ => null
    };

    public bool IsCustomMacMissingOrInvalid =>
        Mode == VmImportMacMode.Custom && MacAddress.Normalize(CustomMac)?.Length != 12;

    public string OriginalMacText => OriginalMacIsStatic
        ? MacAddress.Format(OriginalMac)
        : Resources.VmImport_MacDynamicValue;
}

public sealed class VmImportCheckpointPreview
{
    public string Id { get; init; } = string.Empty;
    public string? ParentId { get; init; }
    public string Name { get; init; } = string.Empty;
    public DateTime Created { get; init; }
    public int Depth { get; set; }
    public string BranchText => Depth <= 0 ? string.Empty : new string(' ', (Depth - 1) * 3) + "└─";
    public string CreatedText => Created == DateTime.MinValue
        ? string.Empty
        : Created.ToString("g", Resources.Culture ?? CultureInfo.CurrentUICulture);
}

/// <summary>导入预览卡片。名称与克隆相关选项由用户在向导中编辑。</summary>
public sealed class VmImportPreview : ObservableObject
{
    private string _name;
    private bool _generateNewGuid;

    public VmImportPreview()
    {
        _name = string.Empty;
        OriginalName = string.Empty;
    }

    /// <summary>来源配置中的原始名称，用于判断用户是否改过名。</summary>
    public string OriginalName { get; init; }

    public string Name
    {
        get => _name;
        set => SetProperty(ref _name, value);
    }

    /// <summary>用户要求导入时生成新 GUID（克隆模板时勾选；GUID 冲突时由服务端预勾选）。</summary>
    public bool GenerateNewGuid
    {
        get => _generateNewGuid;
        set
        {
            if (SetProperty(ref _generateNewGuid, value))
                OnPropertyChanged(nameof(GuidDisplayText));
        }
    }

    public Guid OriginalGuid { get; init; }
    public Guid PlannedGuid { get; init; }
    public bool GeneratedNewGuid => OriginalGuid != Guid.Empty && PlannedGuid != Guid.Empty && OriginalGuid != PlannedGuid;
    public string GuidText => PlannedGuid.ToString("D");
    /// <summary>GUID 徽标文案：勾选“生成新 GUID”后不再展示来源 GUID 本身。</summary>
    public string GuidDisplayText => GenerateNewGuid ? Resources.VmImport_GuidWillRegenerate : GuidText;
    public bool NameChanged => !string.Equals(Name?.Trim(), OriginalName, StringComparison.Ordinal);
    public int Generation { get; init; }
    public string GenerationText => string.Format(
        Resources.Culture ?? CultureInfo.CurrentUICulture,
        Resources.VmImport_GenerationFormat,
        Generation);
    public string ConfigurationVersion { get; init; } = string.Empty;
    public DateTime Created { get; init; }
    public string CreatedText => Created == DateTime.MinValue
        ? "—"
        : Created.ToString("g", Resources.Culture ?? CultureInfo.CurrentUICulture);
    public string Notes { get; init; } = string.Empty;
    public string OsType { get; init; } = "Windows";
    public int ProcessorCount { get; init; }
    public bool DynamicMemory { get; init; }
    public ulong StartupMemoryMb { get; init; }
    public ulong MinimumMemoryMb { get; init; }
    public ulong MaximumMemoryMb { get; init; }
    public bool HasSavedState { get; init; }
    public string SavedStateText => HasSavedState ? Resources.VmImport_Yes : Resources.VmImport_No;
    public ObservableCollection<VmImportDiskPreview> Disks { get; init; } = new();
    public ObservableCollection<VmImportNetworkPreview> Networks { get; init; } = new();
    public ObservableCollection<VmImportCheckpointPreview> Checkpoints { get; init; } = new();
    public ObservableCollection<string> CompatibilityIssues { get; init; } = new();

    public string MemoryText => string.Format(
        Resources.Culture ?? CultureInfo.CurrentUICulture,
        DynamicMemory ? Resources.VmImport_DynamicMemoryFormat : Resources.VmImport_StaticMemoryFormat,
        StartupMemoryMb,
        MinimumMemoryMb,
        MaximumMemoryMb);
    public string StartupMemoryText => string.Format(
        Resources.Culture ?? CultureInfo.CurrentUICulture,
        Resources.VmImport_StaticMemoryFormat,
        StartupMemoryMb);
    public string ConfigSummary
    {
        get
        {
            string diskPart = Disks.Count == 0
                ? Resources.Common_NoDisk
                : string.Join(" + ", Disks
                    .Select(d => d.VirtualSize / 1073741824.0)
                    .OrderByDescending(size => size)
                    .Select(size => size >= 1 ? $"{size:0.#} GB" : $"{size * 1024:0} MB"));

            return string.Format(
                Resources.Culture ?? CultureInfo.CurrentUICulture,
                Resources.Format_VmSummary,
                ProcessorCount,
                StartupMemoryMb / 1024.0,
                diskPart);
        }
    }
    public string ProcessorMemorySummary => string.Format(
        Resources.Culture ?? CultureInfo.CurrentUICulture,
        Resources.VmImport_ProcessorMemoryFormat,
        ProcessorCount,
        StartupMemoryMb / 1024.0);
    public string DiskSummary => Disks.Count == 0 ? "0" : Disks.Count.ToString();
    public string NetworkSummary => Networks.Count == 0 ? "0" : Networks.Count.ToString();
    public string CheckpointSummary => Checkpoints.Count == 0 ? "0" : Checkpoints.Count.ToString();
}
