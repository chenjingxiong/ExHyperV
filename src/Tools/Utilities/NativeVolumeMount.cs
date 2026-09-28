using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace ExHyperV.Tools
{
    /// <summary>
    /// Win32 卷挂载点工具：为（磁盘号, 分区号）定位卷 GUID 路径并挂/卸盘符。
    /// root\Microsoft\Windows\Storage 的 MSFT_Partition 在提供程序损坏的系统上会静默返回空集，
    /// AddAccessPath 流程随之整体失效；本工具不经过 WMI，直接走
    /// IOCTL_DISK_GET_DRIVE_LAYOUT_EX + IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS + SetVolumeMountPoint。
    /// </summary>
    public static class NativeVolumeMount
    {
        private const uint IOCTL_DISK_GET_DRIVE_LAYOUT_EX = 0x00070050;
        private const uint IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x00560000;

        // DRIVE_LAYOUT_INFORMATION_EX 头：PartitionStyle(4)+PartitionCount(4)+GPT/MBR 联合体(40) = 48，
        // 其后紧跟 PARTITION_INFORMATION_EX[PartitionCount]
        private const int DriveLayoutHeaderSize = 48;
        // PARTITION_INFORMATION_EX：Style(4)+pad(4)+StartingOffset(8)+PartitionLength(8)+PartitionNumber(4)
        // +RewritePartition(1)+pad(7)+GPT 联合体(112) = 144
        private const int PartitionInfoSize = 144;
        private const int MaxPartitions = 128;

        // VOLUME_DISK_EXTENTS：NumberOfDiskExtents(4)+pad(4)+DISK_EXTENT[ANYSIZE_ARRAY]
        // DISK_EXTENT：DiskNumber(4)+pad(4)+StartingOffset(8)+ExtentLength(8) = 24
        private const int DiskExtentSize = 24;
        private const int MaxVolumeExtents = 32;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(
            Microsoft.Win32.SafeHandles.SafeFileHandle hDevice, uint dwIoControlCode,
            IntPtr lpInBuffer, int nInBufferSize,
            byte[] lpOutBuffer, int nOutBufferSize,
            out int lpBytesReturned, IntPtr lpOverlapped);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool SetVolumeMountPoint(string lpszVolumeMountPoint, string lpszVolumeName);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool DeleteVolumeMountPoint(string lpszVolumeMountPoint);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr FindFirstVolume(StringBuilder lpszVolumeName, int cchBufferLength);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool FindNextVolume(IntPtr hFindVolume, StringBuilder lpszVolumeName, int cchBufferLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FindVolumeClose(IntPtr hFindVolume);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool GetVolumeInformation(
            string lpRootPathName, StringBuilder lpVolumeNameBuffer, int nVolumeNameSize,
            out uint lpVolumeSerialNumber, out uint lpMaximumComponentLength, out uint lpFileSystemFlags,
            StringBuilder lpFileSystemNameBuffer, int nFileSystemNameSize);

        /// <summary>查分区在磁盘上的字节偏移。</summary>
        public static bool TryGetPartitionOffset(int diskNumber, uint partitionNumber, out ulong startingOffset)
        {
            startingOffset = 0;
            try
            {
                using var diskStream = new FileStream(
                    $@"\\.\PhysicalDrive{diskNumber}", FileMode.Open, FileAccess.Read, FileShare.ReadWrite);

                byte[] layout = new byte[DriveLayoutHeaderSize + PartitionInfoSize * MaxPartitions];
                if (!DeviceIoControl(diskStream.SafeFileHandle, IOCTL_DISK_GET_DRIVE_LAYOUT_EX,
                        IntPtr.Zero, 0, layout, layout.Length, out _, IntPtr.Zero))
                    return false;

                uint count = BitConverter.ToUInt32(layout, 4);
                if (count > MaxPartitions) count = MaxPartitions;

                for (int i = 0; i < count; i++)
                {
                    int off = DriveLayoutHeaderSize + i * PartitionInfoSize;
                    if (BitConverter.ToUInt32(layout, off + 24) == partitionNumber)
                    {
                        startingOffset = BitConverter.ToUInt64(layout, off + 8);
                        return true;
                    }
                }
                return false;
            }
            catch { return false; }
        }

        // 遍历卷 GUID 路径，按磁盘号+字节偏移定位分区对应的卷
        private static string? FindVolumePath(uint diskNumber, ulong startingOffset)
        {
            var nameBuf = new StringBuilder(300);
            IntPtr findHandle = FindFirstVolume(nameBuf, nameBuf.Capacity);
            if (findHandle == IntPtr.Zero) return null;

            try
            {
                do
                {
                    string volumePath = nameBuf.ToString();
                    if (!volumePath.StartsWith(@"\\?\Volume{", StringComparison.OrdinalIgnoreCase)) continue;

                    try
                    {
                        // 卷句柄须去掉结尾反斜杠再 CreateFile；共享位带 Delete 避免与卷卸载互斥
                        using var volumeStream = new FileStream(
                            volumePath.TrimEnd('\\'), FileMode.Open, FileAccess.Read,
                            FileShare.ReadWrite | FileShare.Delete);

                        byte[] extents = new byte[8 + DiskExtentSize * MaxVolumeExtents];
                        if (!DeviceIoControl(volumeStream.SafeFileHandle, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS,
                                IntPtr.Zero, 0, extents, extents.Length, out _, IntPtr.Zero))
                            continue;

                        uint extentCount = BitConverter.ToUInt32(extents, 0);
                        if (extentCount > MaxVolumeExtents) extentCount = MaxVolumeExtents;

                        for (int i = 0; i < extentCount; i++)
                        {
                            int off = 8 + i * DiskExtentSize;
                            if (BitConverter.ToUInt32(extents, off) == diskNumber &&
                                BitConverter.ToUInt64(extents, off + 8) == startingOffset)
                                return volumePath;
                        }
                    }
                    catch { /* 该卷打不开（离线/异构）→ 跳过 */ }
                } while (FindNextVolume(findHandle, nameBuf, nameBuf.Capacity));
            }
            finally { FindVolumeClose(findHandle); }

            return null;
        }

        /// <summary>为指定分区挂载盘符（等价 MSFT_Partition.AddAccessPath）。</summary>
        public static bool TryAssignDriveLetter(int diskNumber, uint partitionNumber, char driveLetter)
        {
            if (!TryGetPartitionOffset(diskNumber, partitionNumber, out ulong startingOffset)) return false;

            string? volumePath = FindVolumePath((uint)diskNumber, startingOffset);
            if (volumePath == null) return false;

            return SetVolumeMountPoint($"{driveLetter}:\\", volumePath);
        }

        /// <summary>移除盘符挂载点（等价 MSFT_Partition.RemoveAccessPath）。</summary>
        public static bool RemoveDriveLetter(char driveLetter)
        {
            return DeleteVolumeMountPoint($"{driveLetter}:\\");
        }

        /// <summary>
        /// 读卷文件系统名；BitLocker 锁定卷拿不到（等价 MSFT_Volume.FileSystem 为空的判定）。
        /// </summary>
        public static string TryGetFileSystemName(char driveLetter)
        {
            var fsName = new StringBuilder(64);
            bool ok = GetVolumeInformation(
                $"{driveLetter}:\\", new StringBuilder(64), 64,
                out _, out _, out _, fsName, fsName.Capacity);
            return ok ? fsName.ToString() : string.Empty;
        }
    }
}
